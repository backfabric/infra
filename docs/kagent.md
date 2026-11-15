# kagent

The `kagent` subsystem installs [kagent](https://kagent.dev/) v1.0.1 and the
Agent Substrate fork it brings (`kagent-dev/substrate` v1.0.0), the agent
platform of [ADR 0029](adr/0029-kagent-agent-platform.md), with kagent's own
installer, `kagent install`, run by a systemd unit
([ADR 0030](adr/0030-kagent-installed-by-its-installer.md)). It is off by
default:

```nix
backfabric.kagent = {
  enable = true;
  model = "gpt-5-mini";                    # the default: the installer's choice
  apiKeySecret = "kagent-openai-api-key";  # the default, in secrets/common.yaml
  dataNode = "node1";                      # the default: this host's name
};
```

kagent needs Kubernetes 1.37 or later (PodCertificateRequest and
ClusterTrustBundle at `certificates.k8s.io/v1`): the host's
`backfabric.k3s.package` must be `k3s_1_37` or newer, from the private
repository's nixpkgs (the configuration is refused otherwise).

| What | Where |
| ---- | ----- |
| kagent CLI | `nix/packages/kagent.nix`: the release binary `kagent-linux-<arch>` v1.0.1, pinned by hash; run by the unit, and on the system's PATH |
| Namespaces | `kagent` and `ate-system` with Pod Security `enforce: privileged`, `podcertificate-controller-system` with `enforce: baseline`, `warn: restricted` (k3s manifest `kagent`) |
| Volumes | PersistentVolumes `kagent-postgresql` (500Mi, claim `kagent/kagent-postgresql`) and `kagent-rustfs` (1Gi, claim `ate-system/rustfs-data`): local volumes in `/var/lib/kagent/{postgresql,rustfs}` on `dataNode`, reclaim policy Retain (manifest `kagent`) |
| Install | unit `kagent-install` (oneshot, at boot and every deployment): `kagent --config <store> install --namespace kagent --provider OpenAI`, helm and kubectl from nixpkgs |
| Marker | ConfigMap `kagent/backfabric-kagent-install` (`stamp`, `version`) |
| Lock | Lease `kagent/backfabric-kagent-install` (`coordination.k8s.io/v1`) while a server installs |
| API key | `apiKeySecret` in `backfabric.secrets.commonFile`, handed to the unit as a systemd credential |

## What `kagent install` installs

In this order, each chart step a `helm upgrade --install … --wait
--wait-for-jobs --timeout 5m` from `oci://ghcr.io/kagent-dev/` (kagent's
`go/core/pkg/install/plan.go`):

1. chart `kagent-crds` 1.0.1 (namespace `kagent`) and `substrate-crds` 1.0.0
   (`ate-system`);
2. Substrate's prerequisites: the label `ate.dev/api-access=true` on
   `kagent`, the CA and JWT pool Secrets (created only if missing), the
   ConfigMap `ate-system/ate-api-authentication`, RustFS's credentials;
3. chart `substrate-podcert` (`podcertificate-controller-system`);
4. the bundled PostgreSQL `kagent/kagent-postgresql` (`postgres:18-alpine`
   by digest) and its setup;
5. chart `substrate-atelet` (`ate-system`), waiting for the DaemonSet;
6. chart `substrate` (`ate-system`);
7. chart `kagent` (`kagent`): the controller, the UI, the WorkerPool
   `kagent-default` (gVisor workers), the Harnesses `kagent-default`,
   `codex-default`, `claude-default`, and the ModelConfig
   `default-model-config` (OpenAI, `model`, Responses API) with the key in
   the Secret `kagent/kagent-openai`.

The first install takes 10 to 20 minutes (a deployment waits for it); the
cluster pulls the charts and images from `ghcr.io` and Docker Hub then.

## What is ours

`nix/packages/kagent.nix` (the CLI binary), and `nix/modules/kagent.nix`:
the k3s manifest (three namespaces with their Pod Security labels, two
local volumes), the CLI config that sets the model, and the unit's script
(wait, stamp, Lease, `kagent install`, marker). Everything the installer
does is upstream and unchanged.

The namespaces exist before the install because the installer sets no
Pod Security labels, and the cluster enforces `restricted` everywhere else:

- `kagent`, `privileged`: the WorkerPool's gVisor worker Deployment runs
  there (root, hostPath `/var/lib/ate`, added capabilities such as
  `SYS_ADMIN` and `NET_ADMIN`, seccomp and AppArmor `Unconfined`); the
  bundled PostgreSQL alone would need `baseline`;
- `ate-system`, `privileged`: the atelet DaemonSet (root, hostPaths
  `/var/lib/ate`, `/var/lib/kubelet/plugins`, `/dev`);
- `podcertificate-controller-system`, `baseline`: its pod sets no seccomp
  profile.

The installer keeps existing labels (it adds `ate.dev/api-access` to
`kagent` and Helm's ownership metadata to `podcertificate-controller-system`
by merge). The volumes exist because the bundled PostgreSQL's and RustFS's
claims name no StorageClass and the cluster has no provisioner (k3s's
`local-storage` is off): each claim is bound to its volume by name, and
both pods run on `dataNode`.

## Install, re-run, several servers

The unit runs at every boot and deployment, on every server that enables
the subsystem. It:

1. waits for the API and the three namespaces with their labels (k3s
   applies the manifest);
2. computes the stamp: SHA-256 over the CLI version, the install
   arguments, the model, and the API key;
3. stops with `kagent is up to date (…)` when the ConfigMap
   `kagent/backfabric-kagent-install` has that stamp and kagent's Helm
   release is `deployed`;
4. otherwise takes the Lease `kagent/backfabric-kagent-install` (waiting up
   to an hour while another server holds it), checks the stamp again, runs
   `kagent install`, writes the stamp, and releases the Lease.

The marker lives in the cluster, not on a host: any server sees it, and a
reinstalled server does not install again. A new CLI version, model or key
changes the stamp and runs the installer again: every chart step is a Helm
upgrade, and the CAs and Secrets that exist are kept. If `kagent install`
fails, no stamp is written and the unit fails; it runs again at the next
deployment or with `systemctl start kagent-install`.

The Lease is created by one server (an atomic create); another server waits
until it is deleted. A Lease left by a killed run is taken over by the same
host at once, by another host after it expires (an hour, longer than an
install): with a replace against the Lease's `resourceVersion`, so two
servers taking over at once cannot both succeed.

Every server must set the same `model`, `apiKeySecret` and `dataNode`, and
use the same CLI version (the same commit of this repository): different
values on two servers would install in turns.

## The API key

An OpenAI API key, added to the cluster-wide sops file (`backfabric keygen`
does not generate it), in the private repository's dev shell, without echo
or an argument (`sops set` takes a JSON string; a key has no quotes or
backslashes, and `printf` is a shell builtin):

```sh
read -rs KEY && printf '"%s"' "$KEY" |
  sops set --value-stdin secrets/common.yaml '["kagent-openai-api-key"]'; unset KEY
sops -d --extract '["kagent-openai-api-key"]' secrets/common.yaml | cut -c1-3   # sk-
```

sops-nix decrypts it to `/run/secrets/kagent-openai-api-key` (root, 0400,
a tmpfs); systemd hands it to the unit as a credential. The CLI reads the
key only from the environment variable `OPENAI_API_KEY`, so the script sets
it for `kagent install` alone (and the `helm` and `kubectl` it runs, while
it runs): never in an argument, the unit's environment, the stamp (a hash
of all inputs together), or a log. The CLI passes it to Helm in a 0600
file in a private temporary directory and hides Helm's output on failure.

In the cluster the key is in the Secret `kagent/kagent-openai` and in Helm's
release records (`sh.helm.release.v1.kagent.v*`, `helm get values kagent -n
kagent` prints it): readable by whoever may read Secrets in `kagent`.

Replacing the key: change it in `secrets/common.yaml`, commit, deploy; the
stamp changes and the unit runs `kagent install` again.

## Status

On a server, as root:

```sh
systemctl status kagent-install
journalctl -u kagent-install
kubectl -n kagent get configmap backfabric-kagent-install -o jsonpath='{.data}'; echo
kubectl get ns kagent ate-system podcertificate-controller-system -L pod-security.kubernetes.io/enforce,ate.dev/api-access
for ns in kagent ate-system podcertificate-controller-system; do kubectl get pods -n "$ns"; done
kubectl -n kagent get workerpools.ate.dev,harnesses.api.kagent.dev,modelconfigs.api.kagent.dev
```

`kagent-install` is `inactive (dead)` with `status=0/SUCCESS`; its log ends
with `kagent installed (…)` or `kagent is up to date (…)`. The ConfigMap
shows `stamp` and `version: 1.0.1`. Every pod is `Running` (or
`Completed`); the Deployments in `ate-system` include `ate-api-server`,
`ate-controller`, `ate-idp-server`, `atenet-egress`, `atenet-router`,
`k8s-credential-provider` and `rustfs`, the DaemonSet `atelet`; in
`kagent` `kagent-controller`, `kagent-ui`, `kagent-postgresql` and the
worker Deployment `kagent-default`.

### UI and API

kagent's Services are ClusterIP and its auth mode is `insecure` (any caller
picks its user with `X-User-Id`); nothing exposes them until agentgateway
fronts kagent ([#112](https://github.com/backfabric/infra/issues/112)).
Reach them through a port-forward on a server and an SSH tunnel:

```sh
kubectl -n kagent port-forward svc/kagent-ui 8082:8080              # on the server
ssh -N -L 8082:localhost:8082 node1                                 # locally, then http://localhost:8082
```

### An agent over A2A

An acceptance check of the platform: an agent on the installed `codex-default` Harness and
`default-model-config`, and a conversation over A2A JSON-RPC (port 8083,
`POST /agents/<namespace>/<name>`, header `A2A-Version: 1.0` required). On
a server, as root:

```sh
kubectl apply -f - <<'EOF'
apiVersion: api.kagent.dev/v1alpha3
kind: AgentTemplate
metadata: { name: codex-template, namespace: kagent }
spec:
  modelConfig: { name: default-model-config }
  systemPrompt: You are a concise, helpful coding assistant.
---
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata: { name: codex-agent, namespace: kagent }
spec:
  template: { ref: { name: codex-template } }
  harnessRef: { name: codex-default }
EOF
kubectl wait --for=condition=Ready agent/codex-agent -n kagent --timeout=600s

kubectl -n kagent port-forward svc/kagent-controller 8083:8083 >/dev/null 2>&1 &
A2A=http://localhost:8083/agents/kagent/codex-agent
HDRS=(-H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -H 'X-User-Id: admin@kagent.dev')
send() {  # send <text> [<contextId>]
  jq -n --arg mid "$(cat /proc/sys/kernel/random/uuid)" --arg text "$1" --arg ctx "${2-}" \
    '{jsonrpc: "2.0", id: "1", method: "SendMessage",
      params: {message: ({messageId: $mid, role: "ROLE_USER", parts: [{text: $text}]}
        + if $ctx == "" then {} else {contextId: $ctx} end)}}' |
    curl -fsS "${HDRS[@]}" --max-time 300 -d @- "$A2A"
}
reply=$(send "What is 7 times 6? Answer with just the number.")
jq '{state: .result.task.status.state, answer: [.result.task.artifacts[]?.parts[]?.text]}' <<<"$reply"
SESSION_ID=$(jq -r .result.task.contextId <<<"$reply")
send "What was the question I just asked you?" "$SESSION_ID" |
  jq '{state: .result.task.status.state, contextId: .result.task.contextId, answer: [.result.task.artifacts[]?.parts[]?.text]}'
```

The first Agent on a template waits for a golden snapshot (minutes). The
first reply is `TASK_STATE_COMPLETED` with `42`; the second has the same
`contextId` (the session) and mentions "7 times 6". A missing
`A2A-Version` header gives a `version not supported` error.

Sessions are suspended between turns and resumed for the next one, inside
the long-lived worker pod. kagent's SessionService shows it (with
`nix shell nixpkgs#grpcurl`; the controller serves gRPC reflection):

```sh
sess() { grpcurl -plaintext -H 'X-User-Id: admin@kagent.dev' -d '{"session_id":"'"$SESSION_ID"'"}' \
  localhost:8083 kagent.api.v1.SessionService/GetSession | jq -r '.session | "\(.state) \(.operation // "")"'; }
sess                                          # RUNTIME_STATE_SUSPENDED
send "One more: what is 9 times 9?" "$SESSION_ID" > /tmp/reply3.json &
for i in $(seq 10); do sess; sleep 2; done; wait
jq -r '[.result.task.artifacts[]?.parts[]?.text] | join(" ")' /tmp/reply3.json   # 81
sess                                          # RUNTIME_STATE_SUSPENDED
kubectl -n kagent get pods -l ate.dev/worker-pool                                 # the same worker pod(s) throughout
```

During the turn the state is `RUNTIME_STATE_READY` with an operation.
Delete the check's agent afterwards (`kubectl -n kagent delete
agent/codex-agent agenttemplate/codex-template`) and stop the
port-forward.

## Upgrading

A new kagent version is a change of the version and both hashes in
`nix/packages/kagent.nix` (the CLI pins the chart versions it installs),
and a deployment: the stamp changes and the unit runs `kagent install`,
Helm upgrades in the installer's order (atelet before Substrate). Read the
release notes first: kagent 1.0's schema "requires a clean database", and
an upgrade may need one (ADR 0029).

## Replacing the certificate authorities

The installer's CAs are valid for 365 days and nothing renews them
([#108](https://github.com/backfabric/infra/issues/108)). kagent's
documented replacement (`helm/README.md` at v1.0.1) is to delete them, run
`kagent install` again and restart the workloads; with the unit, the marker
is deleted too so that it runs:

```sh
kubectl delete secret -n ate-system actor-id-ca-pool actor-id-ca-certs egress-mitm-ca-pool
kubectl delete secret -n podcertificate-controller-system service-dns-ca-pool pod-identity-ca-pool postgres-ca-pool
kubectl -n kagent delete configmap backfabric-kagent-install
systemctl start kagent-install
kubectl -n ate-system rollout restart deployment,daemonset
kubectl -n podcertificate-controller-system rollout restart deployment
kubectl -n kagent rollout restart deployment
```

Running sessions are interrupted.

## Failures

The unit's log names the step; `kagent install` names the failing release.

- `Gave up waiting for the namespace …`: k3s did not apply the manifest
  `kagent`; `journalctl -u k3s | grep kagent`.
- `Gave up waiting for the Lease …`: another server holds it (its
  `holderIdentity`); see that server's `journalctl -u kagent-install`. A
  Lease whose holder is gone expires an hour after it was taken.
- A chart step times out: usually a pod rejected or not starting;
  `kubectl get events -A --field-selector type=Warning | tail -30` (Pod
  Security rejections, image pulls from `ghcr.io` and Docker Hub, a claim
  that stays `Pending` because `dataNode` is not this cluster's node name).
- `start port-forward`: after installing, the CLI checks the controller
  through `kubectl port-forward` on `localhost:8083` of the server; the port
  must be free.

After fixing the cause, `systemctl start kagent-install` (or deploy again)
runs the install again; what exists is upgraded, not recreated.

## Turn off

Turning the subsystem off uninstalls nothing: kagent's state (agents,
sessions, the database, the CAs) stays until it is removed on purpose, in
this order. As root on a server, while the subsystem is still on (it puts
the `kagent` CLI on the system's PATH; `kagent uninstall` also needs helm
and a kubeconfig): `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`, then

1. Delete your own kagent objects (Agents before their AgentTemplates)
   while the controller still runs their finalizers:
   `kubectl -n kagent delete agents.api.kagent.dev --all --wait` and the
   same for `agenttemplates.api.kagent.dev`.
2. Run kagent's uninstaller, which removes the releases and CRDs in the
   right order, the bundled PostgreSQL with its claim and Secrets, the
   namespaces `ate-system` and `podcertificate-controller-system`, and
   Substrate's ClusterTrustBundles:
   `nix shell nixpkgs#kubernetes-helm -c kagent uninstall --namespace kagent --delete-worker-pools`.
3. Set `backfabric.kagent.enable = false` and list the manifest as removed,
   in the same commit, and deploy:

   ```nix
   backfabric.kagent.enable = false;
   backfabric.k3s.removedManifests = [ "kagent" ];
   ```

   ```sh
   backfabric deploy node1
   ```

   k3s deletes the namespace `kagent` (with the marker, the Lease and
   anything left in it), the other two if they came back, and the two
   volumes. The deployment restarts k3s. Never set `enable = false` without
   the `removedManifests` entry: the manifest's link would stay and dangle
   once its store path is collected, which stops k3s from applying any
   manifest.
4. Remove the host state no object owns, on `dataNode` and every node that
   ran a worker or atelet:
   `rm -rf /var/lib/kagent /var/lib/ate`, and
   `rm -f /var/lib/kubelet/device-plugins/ate.dev-kvm-*.sock`.

Check: `kubectl get ns kagent ate-system podcertificate-controller-system`
finds none; `kubectl get crd -o name | grep -E '\.kagent\.dev$|\.ate\.dev$'`
and `kubectl get clustertrustbundles -o name | grep ate.dev` print nothing;
`kubectl -n kube-system get addon kagent` is not found.

## Known production gaps

Each has its issue:

- the CA pools expire after 365 days, nothing rotates them
  ([#108](https://github.com/backfabric/infra/issues/108));
- kagent's and Substrate's state is in the bundled PostgreSQL, one
  instance on one node, without backups
  ([#109](https://github.com/backfabric/infra/issues/109));
- most images are pulled by tag at install time
  ([#110](https://github.com/backfabric/infra/issues/110));
- the whole `kagent` namespace is privileged because the worker pool lives
  there ([#111](https://github.com/backfabric/infra/issues/111));
- kagent's auth mode is `insecure` until agentgateway fronts it: access
  only by port-forward ([#112](https://github.com/backfabric/infra/issues/112));
- RustFS runs with its chart's default credentials
  ([#113](https://github.com/backfabric/infra/issues/113)).
