# Agent Substrate

[Agent Substrate](https://github.com/agent-substrate/substrate) runs
stateful agent workloads ("actors") in gVisor sandboxes on warm worker pods
and suspends them to snapshots in object storage. The `substrate` subsystem
(`nix/modules/substrate.nix`, off unless `backfabric.substrate.enable`)
installs release v1.0.0 on the host's cluster with Substrate's own
installer. Why, and the options considered:
[ADR 0023](adr/0023-agent-substrate-runtime.md).

## What runs where

| What | Where | Data |
| ---- | ----- | ---- |
| `substrate-install` (oneshot) | host | `/var/lib/substrate-install`: ate-setup's record of the last run (`installs/default.yaml`, `failed/`) |
| podcertificate-controller | namespace `podcertificate-controller-system` (Pod Security `restricted`) | CA pools in Secrets |
| ate-api-server, ate-idp-server, ate-controller, atenet-router, atenet-egress | `ate-system` | |
| atelet (DaemonSet) | `ate-system` | `/var/lib/ate` on the host |
| PostgreSQL 18 (Substrate's bundled StatefulSet, mutual TLS with pod certificates) | `ate-system` | `/var/lib/substrate/postgres` (static local volume `postgres`, 10Gi) |
| RustFS (S3) and the Job creating the bucket `ate-snapshots` | `ate-system` | `/var/lib/substrate/rustfs` (static local volume `rustfs`, nominally 100Gi) |
| worker pods of a WorkerPool | a namespace of `backfabric.substrate.workerPoolNamespaces` | `/var/lib/ate` on the host |

ate-setup applies Substrate's manifests (from the package, with the patches
listed below); k3s applies the rest from
`/var/lib/rancher/k3s/server/manifests`: `substrate-volumes.yaml` (the two
volumes), `substrate-rustfs.yaml` (the `ate-system` Namespace, RustFS, its
claim, Service, bucket Job and NetworkPolicy),
`substrate-rustfs-credentials.yaml` (the Secret
`ate-system/rustfs-credentials`, a link to
`/run/secrets/rendered/substrate-rustfs-credentials.yaml`), and the k3s
module's `backfabric-exempt-namespace-images.yaml` (below).

The volumes are bound to their claims by name (`claimRef`) and use the class
`backfabric-local`, for which no StorageClass and no provisioner exists:
nothing else in the cluster can get a volume. Their capacity is not
enforced; PostgreSQL and the snapshots share the host's file system.

## Enable

1. In the private repository, generate the RustFS credentials
   (`rustfs-access-key`, `rustfs-secret-key` in `secrets/common.yaml`) and
   commit. `backfabric keygen` creates them for every fleet, whether or not
   a host enables Substrate:

   ```sh
   backfabric keygen
   git add secrets && git commit -m "chore: add the RustFS credentials"
   ```

2. On the host:

   ```nix
   backfabric.substrate = {
     enable = true;
     # Namespaces that will hold WorkerPools (see "WorkerPools" below).
     workerPoolNamespaces = [ "agents" ];
   };
   ```

   and deploy it.

The deployment restarts k3s with the new feature gates (the API server is
unavailable for a short while), then `substrate-install` runs:

- it waits up to 5 minutes for the API server and up to 1 minute for the
  resources `clustertrustbundles` and `podcertificaterequests` of
  `certificates.k8s.io/v1beta1`;
- it runs `ate-setup deploy ate-system --config <SubstrateInstall>` in the
  package's manifest tree. ate-setup resolves the image tags to digests at
  ghcr.io, applies the CRDs, the gVisor SandboxConfig, the pod certificate
  controller, PostgreSQL, the control plane and atelet, and waits for each
  rollout (5 minutes each). `TimeoutStartSec` is 30 minutes.

It runs again whenever the package or the SubstrateInstall document
changes, and at boot; ate-setup applies idempotently. A failed run is not
restarted: the deployment reports the failed unit.

```sh
systemctl status substrate-install
journalctl -u substrate-install -b
```

The journal starts with ate-setup's report: every setting and where it came
from.

## Checks

As root on the host:

```sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# The beta resources Substrate needs: both names.
kubectl get --raw /apis/certificates.k8s.io/v1beta1 | jq -r '.resources[].name'
# Pods: everything Running, the bucket Job Completed.
kubectl -n podcertificate-controller-system get pods
kubectl -n ate-system get pods,pvc
kubectl get pv postgres rustfs           # both Bound
kubectl get clustertrustbundles          # Substrate's signers, label podcert.ate.dev/canarying=live
kubectl get sandboxconfigs               # gvisor-default only
kubectl -n ate-system logs job/rustfs-bucket-init   # "bucket ate-snapshots created" or "already exists"
kubectl ate get atespaces                # answers: the API and kubectl-ate's identity work
# Pods with images outside the allowlist (see below): 0.
grep validation_failure /var/lib/rancher/k3s/server/logs/audit.log | grep -c backfabric-exempt-namespace-images
```

## Smoke test

`backfabric.substrate.smokeTest.enable = true;` exempts the namespace
`substrate-smoke` like a WorkerPool namespace and installs its manifests in
`/etc/substrate/smoke/`: a gVisor WorkerPool with one worker, and an actor
template whose container (python:3.14-alpine, pinned by digest) counts POST
requests in memory and in `/data/counter` on its durable volume (upstream's
demo images are not published with the release). A stateful round trip
through a suspend:

```sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl apply -f /etc/substrate/smoke/workerpool.yaml
kubectl -n substrate-smoke get pods      # one worker pod, Running and Ready

kubectl ate create atespace substrate-smoke
kubectl ate create actor-template -f /etc/substrate/smoke/actor-template.yaml
kubectl ate get actor-template counter -a substrate-smoke   # wait until its golden snapshot is ready
kubectl ate create actor smoke-1 -a substrate-smoke --template counter

# Forwards local port 8000 to port 80 of the actor through atenet-router.
kubectl ate proxy actor smoke-1 -a substrate-smoke &

curl -X POST http://localhost:8000       # memory=1 file=1
curl -X POST http://localhost:8000       # memory=2 file=2
kubectl ate suspend actor smoke-1 -a substrate-smoke --mode=sync
kubectl ate get actor smoke-1 -a substrate-smoke             # suspended
curl -X POST http://localhost:8000       # memory=3 file=3: resumed from the snapshot
```

`--mode=sync` returns once the snapshot is in RustFS. Both counters
continuing shows the memory snapshot (`SNAPSHOT_FIDELITY_MEMORY`) and the
durable volume survived. Clean up, then turn `smokeTest.enable` off again:

```sh
kill %1
kubectl ate delete actor smoke-1 -a substrate-smoke
kubectl ate delete actor-template counter -a substrate-smoke
kubectl ate delete atespace substrate-smoke
kubectl delete -f /etc/substrate/smoke/workerpool.yaml
```

## WorkerPools

Worker pods run as root with a host path, SYS_ADMIN, NET_ADMIN and seven
more capabilities, seccomp and AppArmor Unconfined, so their namespace must
be exempt from Pod Security. List it in
`backfabric.substrate.workerPoolNamespaces`: it is exempt, and its pods may
only run the release's gVisor worker image,
`ghcr.io/agent-substrate/substrate/ateworker-gvisor:v1.0.0@sha256:f8987236c6256f58c4b2625e543b43f4ae4bdded6ee6821c03d966effb7c0f17`
(as `workerImage` of every WorkerPool there). The actors' images run inside
the worker's sandbox, not as containers of the pod, and are not limited by
this. The namespaces, WorkerPools, actor templates, actors and egress
policies are the consumer's: the private repository applies them.

Suspend a WorkerPool's running actors before deleting or replacing it
(`kubectl ate suspend actor <name> -a <atespace> --mode=sync`): deleting the
worker pods under a running actor leaves it `ACTOR_STATE_CRASHED` (seen on
node1). Suspended actors resume on the new pool's workers.

### Example: agent-0

One actor of this repository's [agent image](agent-image.md) (Codex behind
an A2A supervisor, port 8080), logged in once with the user's ChatGPT
subscription and kept across suspends. With `workerPoolNamespaces = [
"agents" ];` on the host, the private repository applies:

`workerpool.yaml` (kubectl):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: agents
---
apiVersion: ate.dev/v1
kind: WorkerPool
metadata:
  name: agents
  namespace: agents
  labels:
    workload: agents
spec:
  replicas: 1
  workerImage: ghcr.io/agent-substrate/substrate/ateworker-gvisor:v1.0.0@sha256:f8987236c6256f58c4b2625e543b43f4ae4bdded6ee6821c03d966effb7c0f17
  sandboxClasses:
    - name: gvisor
  # Limits: the worker's capacity for actors; requests: what the scheduler
  # reserves.
  template:
    resources:
      limits: {cpu: "2", memory: 4Gi}
      requests: {cpu: 250m, memory: 4Gi}
```

`actor-template.yaml` (`kubectl ate create actor-template -f`, the
template's protojson form): the image's entrypoint, the supervisor; its
home, with Codex's login and session and the work directory, on a
`durableDir`; memory snapshots. The image is the one published for a commit
of this repository ([Published images](agent-image.md#published-images)),
pinned by digest.

```yaml
metadata:
  atespace: agents
  name: codex
workerSelector:
  matchLabels:
    workload: agents
containers:
  - name: agent
    image: ghcr.io/backfabric/agent@sha256:<digest>
    wakeupProbe:
      httpGet: {path: /healthz, port: 8080}
    volumeMounts:
      - {name: home, mountPath: /home/agent}
resources:
  limits: {cpuMillicores: 2000, memoryBytes: 2147483648}
snapshotConfig:
  preferredFidelity: SNAPSHOT_FIDELITY_MEMORY
volumes:
  - name: home
    durableDir: {}
```

`egress-policy.yaml` (`kubectl ate create egress-policy <actor>`): an egress
policy belongs to an actor, not to a template (templates only have the
preview `goldenEgressPolicy`); without one the actor reaches nothing and
resolves no name. TLS passthrough on 443 to exactly:

```yaml
rules:
  - tlsPassthrough:
      hostnames: [auth.openai.com, chatgpt.com]
      ports:
        numbers: [443]
```

| Host | Why (codex-rs at `rust-v0.167.2`, the version in the image) |
| ---- | ---- |
| `auth.openai.com` | `codex login --device-auth`: `/api/accounts/deviceauth/usercode` and `/api/accounts/deviceauth/token`; token exchange and refresh `/oauth/token` (`login/src/server.rs` `DEFAULT_ISSUER`, `login/src/device_code_auth.rs`, `login/src/auth/manager.rs`) |
| `chatgpt.com` | the model with a ChatGPT login: `https://chatgpt.com/backend-api/codex` (`model-provider-info` `CHATGPT_CODEX_BASE_URL`), and the account endpoints under `backend-api` |

Passthrough rather than `https`: the gateway does not intercept, so the
actor needs no MITM CA and WebSockets inside TLS work. Left out on purpose:
`ab.chatgpt.com` (Codex's Statsig metrics), `github.com`/`api.github.com`
(the plugin sync), `api.openai.com` (API-key use); Codex carries on without
them.

The image must be public on ghcr.io (atelet pulls without credentials).

```sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl apply -f workerpool.yaml
kubectl -n agents get pods               # one worker pod, Running and Ready

kubectl ate create atespace agents
kubectl ate create actor-template -f actor-template.yaml
kubectl ate get actor-template codex -a agents   # wait until its golden snapshot is ready
kubectl ate create actor agent-0 -a agents --template codex
kubectl ate create egress-policy agent-0 -a agents -f egress-policy.yaml

kubectl ate proxy actor agent-0 8000:8080 -a agents &
curl -s -X POST localhost:8000/login     # {"verification_url", "user_code"}
```

Open `verification_url` in a browser, sign in with the ChatGPT account and
enter `user_code`. Then:

```sh
curl -s localhost:8000/login             # "logged_in": true
curl -s localhost:8000/.well-known/agent-card.json   # JSONRPC, protocolVersion 1.0

a2a() {
  curl -s localhost:8000/ -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -d "$1"
}
a2a '{"jsonrpc": "2.0", "id": 1, "method": "SendMessage", "params": {
  "message": {"role": "ROLE_USER", "messageId": "m1", "contextId": "c1",
    "parts": [{"text": "Say hello"}]}}}'
# .result.task: TASK_STATE_COMPLETED, the answer in artifacts[0].parts[0].text

kubectl ate suspend actor agent-0 -a agents --mode=sync
curl -s localhost:8000/login             # still logged in, after the resume
a2a '{"jsonrpc": "2.0", "id": 2, "method": "SendMessage", "params": {
  "message": {"role": "ROLE_USER", "messageId": "m2", "contextId": "c1",
    "parts": [{"text": "What did I ask you before?"}]},
  "configuration": {"returnImmediately": true}}}'
# .result.task: TASK_STATE_WORKING; then, with its id, until COMPLETED:
a2a '{"jsonrpc": "2.0", "id": 3, "method": "GetTask", "params": {"id": "<task id>"}}'
```

The gateway caches a missing policy as deny for 10 seconds, so wait that
long if the login was tried before the policy existed. Gateway decisions:
`kubectl -n ate-system logs deploy/atenet-egress -c ext-proc | grep agent-0`.

The snapshots in RustFS hold the agent's Codex login: whoever can read
`/var/lib/substrate/rustfs` can use the subscription. Remove agent-0:

```sh
kill %1
kubectl ate delete actor agent-0 -a agents
kubectl ate delete actor-template codex -a agents
kubectl ate delete atespace agents
kubectl delete -f workerpool.yaml
```

## Image allowlist of the exempt namespaces

In exchange for the Pod Security exemptions, the ValidatingAdmissionPolicy
`backfabric-exempt-namespace-images` (k3s module, [ADR 0024](adr/0024-pod-security-exemptions-for-pinned-images.md), manifest
`backfabric-exempt-namespace-images.yaml`, applied before the `substrate-*`
files) limits the pods of each namespace in
`backfabric.k3s.podSecurityExemptions` to its list of images, exact
references pinned by digest: every container, init container and ephemeral
container, on every create and update of a pod and of its ephemeral
containers. Controllers' pod templates are checked when they create the
pods.

- `ate-system`: the release's `ate-idp-server`, `ateapi`, `atecontroller`,
  `atelet`, `atenet`, `objectstore-plugin` and `envoy-dataplane` as
  `ghcr.io/agent-substrate/substrate/<name>:v1.0.0@<digest>` (the form
  ate-setup writes after resolving the tag), upstream's
  `postgres:18-alpine@sha256:…`, RustFS and aws-cli.
- each WorkerPool namespace (`agents`, `substrate-smoke`): the
  `ateworker-gvisor` image.

The digests are pinned in `nix/packages/substrate.nix`. Building the package
checks that the `ate-system` list is exactly the set of images the patched
manifests produce, so a new release cannot add one unnoticed.

The binding rejects (`validationActions: [Deny, Audit]`): a pod with an
unlisted image is not created, the client (ate-setup, a controller,
`kubectl`) gets the policy's message, and the audit log records it. To try
a new list without blocking anything, set
`backfabric.k3s.denyUnlistedImages = false;` (`[Warn, Audit]`: admitted with
a warning) and look for failures:

```sh
grep validation_failure /var/lib/rancher/k3s/server/logs/audit.log | grep backfabric-exempt-namespace-images |
  jq -c '{verb, ns: .objectRef.namespace, name: .objectRef.name,
    failure: .annotations["validation.policy.admission.k8s.io/validation_failure"]}'
journalctl -u substrate-install -u k3s -b | grep "ValidatingAdmissionPolicy 'backfabric-exempt-namespace-images'"
```

The policy pins images, not security contexts: within an exempt namespace a
listed image may run with any privileges, and Substrate's `ate-system`
images include some with a shell (PostgreSQL, aws-cli, RustFS). ADR 0023 and ADR
0024 list this residual risk.

## Disable

Set `backfabric.substrate.enable = false;` (the default) and deploy. The
module then lists its k3s manifests in `backfabric.k3s.removedManifests`,
the k3s feature gates and runtime-config go, and k3s deletes what those
manifests applied:

- `substrate-volumes`: the PersistentVolumes `postgres` and `rustfs`
  (reclaim policy Retain: the data stays on the host);
- `substrate-rustfs`: the `ate-system` Namespace, and with it everything in
  it, also what ate-setup created there (the control plane, atelet,
  PostgreSQL, RustFS, their Secrets and claims);
- `substrate-rustfs-credentials`: the Secret (already gone with the
  namespace).

Substrate's Pod Security exemptions (`ate-system`, every WorkerPool
namespace, `substrate-smoke`) and their entries in the image policy end
with the same deployment; the k3s module removes the policy itself only
when no other subsystem exempts a namespace (ADR 0024). **What stays:**

- the WorkerPool namespaces, their WorkerPools and their privileged worker
  pods, now without a Pod Security exemption (running pods are not
  evicted) and without the image policy, and no ate-controller to manage
  them;
- Substrate's CRDs (`workerpools`, `sandboxconfigs`, `csidriverconfigs` in
  `ate.dev`) and the SandboxConfig `gvisor-default`;
- the ClusterRoles and ClusterRoleBindings `ate-api-server`,
  `ate-controller`, `atelet`, `podcert-ate-dev-signer`;
- the ValidatingAdmissionPolicy and binding `sandboxconfig-assets`;
- the namespace `podcertificate-controller-system` and the pod certificate
  controller;
- the ClusterTrustBundles of Substrate's signers
  (`*.podcert.ate.dev/identity`) and any PodCertificateRequests, in etcd
  but no longer served once the feature gates and runtime-config are gone,
  so they cannot be listed or deleted afterwards;
- `/var/lib/substrate` (PostgreSQL and the snapshots, including agents'
  logins), `/var/lib/ate` (atelet's image cache and actor state) and
  `/var/lib/substrate-install` on the host.

On a host that never had Substrate the same three `--disable` entries are
there from the start; they remove nothing, but adding them restarts k3s
once (pods keep running).

Remove everything, in this order, as root on the host:

1. While Substrate is still enabled, delete the actors (and their
   snapshots), templates and atespaces with `kubectl ate`, then the
   WorkerPools, and wait until their worker pods are gone:

   ```sh
   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
   kubectl ate get actors -A                # delete each: kubectl ate delete actor <name> -a <atespace>
   kubectl delete workerpools --all -A
   kubectl get pods -A -l ate.dev/worker-pool   # until none
   ```

   Remove the WorkerPool namespaces from the private repository's
   manifests and delete them (`kubectl delete namespace agents`).

   Still while enabled (these resources are only served with Substrate's
   feature gates): delete the pod certificate controller's namespace first,
   so that nothing publishes the trust bundles again, then the bundles of
   Substrate's signers and any remaining PodCertificateRequests:

   ```sh
   kubectl delete namespace podcertificate-controller-system --wait
   kubectl get clustertrustbundles -o json |
     jq -r '.items[] | select(.spec.signerName | endswith(".podcert.ate.dev/identity")) | .metadata.name' |
     xargs -r kubectl delete clustertrustbundle
   kubectl delete podcertificaterequests --all -A
   kubectl get clustertrustbundles,podcertificaterequests -A   # none of Substrate's left
   ```

   From here on Substrate's pods cannot renew their certificates: go on
   with step 2 right away.

2. Disable Substrate in the host's configuration and deploy (the removal
   above).

3. Delete the cluster-wide leftovers:

   ```sh
   kubectl delete crd workerpools.ate.dev sandboxconfigs.ate.dev csidriverconfigs.ate.dev
   kubectl delete validatingadmissionpolicybinding sandboxconfig-assets --ignore-not-found
   kubectl delete validatingadmissionpolicy sandboxconfig-assets --ignore-not-found
   kubectl delete clusterrolebinding ate-api-server ate-controller atelet podcert-ate-dev-signer --ignore-not-found
   kubectl delete clusterrole ate-api-server ate-controller atelet podcert-ate-dev-signer --ignore-not-found
   ```

4. Delete the data on the host (irreversible; the snapshots hold agents'
   logins): `rm -rf /var/lib/substrate /var/lib/ate /var/lib/substrate-install`.
   Then check that nothing of Substrate is left:

   ```sh
   kubectl get ns                           # no ate-system, podcertificate-controller-system or WorkerPool namespaces
   kubectl get crd | grep ate.dev           # nothing
   kubectl get clusterrole,clusterrolebinding,validatingadmissionpolicy | grep -E 'ate-|atelet|podcert|sandboxconfig'   # nothing
   kubectl get pv                           # no postgres, rustfs
   ```

## What differs from upstream

The SubstrateInstall document (`substrate-install.yaml` in the unit's
script) sets:

| Setting | Value | Why |
| ------- | ----- | --- |
| `kubeconfig`, `context` | `/etc/rancher/k3s/k3s.yaml`, `default` | k3s's; with no context and `gcp.projectID` set, ate-setup would run `gcloud container clusters get-credentials` |
| `images.repo`, `images.tag` | `ghcr.io/agent-substrate/substrate`, `v1.0.0` | the release's public images instead of building with ko |
| `sandboxClasses` | `gvisor` | no microVM: no `/dev/kvm`, no asset staging (default `gvisor,microvm`) |
| `atenet.egress.credentialProvider` | `{"enabled":false}` | no egress credential injection |
| `ingressAllowedSPIFFEIDs` | `spiffe://cluster.local/ns/ate-system/sa/atenet-client` | only `kubectl ate proxy` may reach actors (no default: unset, nothing can) |
| `ateapi.authz.bootstrapOwners` | `system:serviceaccount:ate-system:ate-client` | the default, pinned |
| `ateapi.postgres.storageClass` | `backfabric-local` | the bundled PostgreSQL's claim binds to the static volume |
| `storage.snapshotLocation` | `s3://ate-snapshots/` | the RustFS bucket (required; kind uses `gs://ate-snapshots/` with the same S3 backend) |
| `storage.transferGSAName`, `gcp.projectID` | `unused-with-s3` | required by ate-setup on every install that is not kind, used only by the GCS backend; the S3 backend ignores the resulting `ATE_API_SNAPSHOT_TRANSFER_SERVICE_ACCOUNT` |
| `rolloutTimeout` | `5m` | instead of `1m`: the first install pulls every image |
| `record.dir` | `/var/lib/substrate-install` | ate-setup's records in the unit's state directory |

ate-setup cannot be pointed at a kustomize overlay of its own (it picks
`manifests/ate-install/base` or `kind`), so `nix/packages/substrate.nix`
patches the paths it reads:

- `base/kustomization.yaml` gets kustomize patches: the objectstore-plugin
  sidecars of atelet and ate-api-server use S3 at
  `http://rustfs.ate-system.svc:9000` (path style), with the credentials
  from the Secret `rustfs-credentials` instead of the literals of upstream's
  kind overlay; atelet loses GKE's kubelet credential provider (the two
  host paths, which would be created on the host, and the two flags), so
  actor images are pulled anonymously and must be public.
- `ate-otel-config.yaml` (the ConfigMap every component reads) no longer
  points at GKE's managed collector: traces and metrics `none` (which also
  turns off the Prometheus pull endpoints), logs to the console, the same
  for worker pods. The host's Collector needs a service account token with
  audience `otel-collector`, which Substrate does not send.
- `base/kustomization.yaml` no longer lists `atenet-router-monitoring.yaml`,
  a `PodMonitoring` (`monitoring.googleapis.com/v1`) for Google Managed
  Prometheus: the CRD exists only on GKE (upstream's kind overlay leaves it
  out too). The package build checks that every object ate-setup applies
  for this install is of a Kubernetes API group (`""`, `apps`, `batch`,
  `autoscaling`, `policy`, `*.k8s.io`) or of a CRD in the tree (`ate.dev`),
  so a release that adds such a resource fails the build instead of the
  install.
- `postgres/postgres.yaml`: the data claim asks for 10Gi instead of 500Gi.
- `pod-certificate-controller.yaml`: pod seccomp profile `RuntimeDefault`,
  the only thing its pod lacked for Pod Security `restricted`, so its
  namespace is not exempt.

Each patch checks what it replaces, so a new release that changes it fails
the build instead of being patched silently.

k3s, only with Substrate enabled:

- feature gates `ClusterTrustBundle`, `ClusterTrustBundleProjection`,
  `PodCertificateRequest` on the API server, the controller manager
  (`--kube-*-arg=feature-gates=`) and the kubelet (`featureGates` in its
  configuration file). All three are beta and off by default in 1.35 and
  1.36, and both resources are served only as `v1beta1`
  (`pkg/features/kube_features.go`); the controller manager runs the
  ClusterTrustBundle publisher and the PodCertificateRequest cleaner only
  with them.
- `--kube-apiserver-arg=runtime-config=certificates.k8s.io/v1beta1/clustertrustbundles=true,certificates.k8s.io/v1beta1/podcertificaterequests=true`:
  the two resources, not the whole group version as upstream's kind
  cluster enables.
- Pod Security exemptions (`backfabric.k3s.podSecurityExemptions`):
  `ate-system` (atelet runs as root with host paths, including `/dev`, and
  four capabilities; the bundled PostgreSQL's main container runs as root;
  the other workloads set no seccomp profile) and the WorkerPool
  namespaces.

RustFS (from upstream's `kind/rustfs.yaml`): image pinned by digest,
non-root (10001), all capabilities dropped, seccomp `RuntimeDefault`, a
read-only root file system with `/logs` and `/tmp` in memory, no web
console (upstream enables it on 9001), no service account token, one
replica with the `Recreate` strategy. Its NetworkPolicy admits port 9000
only from atelet, ate-api-server and the bucket Job; ate-system denies all
other ingress (upstream's `ate-system-networkpolicies.yaml`). The bucket Job
runs as nobody with the same restrictions.

## Open questions

- Snapshots under `/var/lib/substrate/rustfs` have no quota; nothing yet
  watches their disk use.
- The pod certificate features are beta: a Kubernetes minor upgrade must
  check that the gates and the `v1beta1` resources still exist (or moved to
  `v1`) before k3s is upgraded.
- A new Substrate release means new digests in `nix/packages/substrate.nix`;
  the build checks catch new images and API groups, not changed security
  contexts.
