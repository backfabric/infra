# Hatchet

The `hatchet` subsystem runs [Hatchet](https://hatchet.run/), the
platform's task queue, in the cluster (ADR 0027), on the
[platform PostgreSQL](postgres.md). It is off by default and needs the
`postgres` subsystem:

```nix
backfabric.postgres.enable = true;
backfabric.hatchet = {
  enable = true;
  # Namespaces whose pods may use the engine; each gets a client token.
  clientNamespaces = [ "dispatcher" ];
};
```

It adds the database `hatchet` (owner `hatchet`, namespace `hatchet`) to
`backfabric.postgres.databases`.

| What | Where |
| ---- | ----- |
| Engine (gRPC, no TLS) | Deployment and Service `hatchet-engine`, `hatchet-engine.hatchet.svc:7070` |
| API | Deployment and Service `hatchet-api`, port 8080, reachable only from the dashboard |
| Dashboard | Deployment and Service `hatchet-frontend`, port 8080, proxies `/api` to the API; port-forward only |
| Database | `hatchet` on the platform PostgreSQL, Secret `hatchet/postgres-hatchet`; messages queue in it too (`SERVER_MSGQUEUE_KIND=postgres`) |
| Encryption keys, cookie secrets | Secret `hatchet/hatchet-keys` |
| Dashboard admin | Secret `hatchet/hatchet-admin` (`ADMIN_EMAIL`, `ADMIN_PASSWORD`) |
| Client tokens | Secret `hatchet/hatchet-token-<namespace>`, copied to `<namespace>/hatchet-client-token` |
| Manifest | k3s manifest `hatchet` (images pinned by digest) |
| Generator | unit `hatchet-credentials` on the host |

Every pod passes Pod Security `restricted`. NetworkPolicy denies all
ingress and egress in `hatchet` except: DNS; PostgreSQL; the engine's
gRPC from the API, from itself (its internal client) and from
`clientNamespaces`; the API from the dashboard; the Kubernetes API from
the setup Jobs. Sign-up, invites and tenant creation are off: the only
user is the seeded admin, the only tenant `Default`.

## Status

On the host, as root:

```sh
kubectl -n hatchet get deployment,pod,secret
systemctl status hatchet-credentials        # last run
journalctl -u hatchet-credentials           # what it generated or waited for
kubectl -n hatchet logs deployment/hatchet-engine
kubectl -n hatchet logs deployment/hatchet-api -c migrate   # also -c seed, -c api
```

Healthy: the three Deployments `READY 1/1`; Secrets
`hatchet-admin`, `hatchet-keys`, `postgres-hatchet` and one
`hatchet-token-<namespace>` per client namespace; none of Hatchet's
startup errors about the database or its timezone (Hatchet logs its
database at level warn, so a healthy start says nothing about it):

```sh
for d in engine api; do
  kubectl -n hatchet logs deployment/hatchet-$d --all-containers |
    grep -E 'timezone is set|could not (connect to|create temporary connection to|query)|failed to open DB'
done   # nothing
```

## The dashboard

From the operator machine, with the fleet SSH config (the API server and
the dashboard are not reachable from outside):

```sh
ssh -L 8080:127.0.0.1:8080 node1 kubectl -n hatchet port-forward svc/hatchet-frontend 8080:8080
```

Open <http://localhost:8080> (exactly this address: the session cookie
and `SERVER_URL` are set for it) and log in as `admin@example.com` with:

```sh
ssh node1 kubectl -n hatchet get secret hatchet-admin -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d
```

The login page shows a "Sign up" link in any case (Hatchet v0.114.2's
dashboard has no setting to hide it); the server refuses registrations.
With the port-forward open:

```sh
curl -s localhost:8080/api/v1/meta | grep -o '"allowSignup":[a-z]*'   # "allowSignup":false
curl -s -X POST localhost:8080/api/v1/users/register -H 'Content-Type: application/json' \
  -d '{"name":"x","email":"x@example.com","password":"Xx123456789"}'      # 400, "user signups are disabled"
```

## Clients

A pod in a namespace of `clientNamespaces` reaches the engine and loads
the Hatchet SDK's settings from the Secret `hatchet-client-token`. The
namespace belongs to the module that runs the client, which creates it
with its NetworkPolicies; `hatchet-credentials` does not create it, and
skips a listed namespace that does not exist yet (it logs so), copying the
token at its next run (the next deployment, or `systemctl start
hatchet-credentials`).

```yaml
envFrom:
  - secretRef: { name: hatchet-client-token }
# HATCHET_CLIENT_TOKEN: a token of the tenant Default
# HATCHET_CLIENT_HOST_PORT: hatchet-engine.hatchet.svc:7070
# HATCHET_CLIENT_TLS_STRATEGY: none
```

The token's `server_url` claim is `http://localhost:8080`: clients that
call Hatchet's REST API need the dashboard's port-forward; workers and
everything over gRPC (registering workers, triggering runs, waiting for
results) do not. A pod in any other namespace has its connections to the
engine refused (kube-router rejects them): the SDK fails with gRPC
`UNAVAILABLE` "Connection refused" at once, not after a timeout.

### Engine access check

A plain TCP connection to the engine from a namespace, with the engine's
own image (pinned; nothing is downloaded at runtime). On the host, as
root. `hatchet_test_ns` creates a namespace as a client's module would:
default deny for ingress and egress, egress only to DNS and the engine.

```sh
hatchet_test_ns() {
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata: { name: $1 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: $1 }
spec: { podSelector: {}, policyTypes: [Ingress, Egress] }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: dns-and-hatchet-engine, namespace: $1 }
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to: [ { namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }, podSelector: { matchLabels: { k8s-app: kube-dns } } } ]
      ports: [ { protocol: UDP, port: 53 }, { protocol: TCP, port: 53 } ]
    - to: [ { namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: hatchet } }, podSelector: { matchLabels: { app.kubernetes.io/name: hatchet-engine } } } ]
      ports: [ { protocol: TCP, port: 7070 } ]
YAML
}

# Prints "connected" or "refused" (it retries for 10 s: kube-router admits
# a new pod's address with a delay).
hatchet_tcp_check() {
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata: { name: hatchet-tcp-check, namespace: $1 }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: check
      image: ghcr.io/hatchet-dev/hatchet/hatchet-engine:v0.114.2@sha256:247120b5fabb0085784d3adcf4aebfaca670a400c950d7f53d7ea95c858b4f21
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      command:
        - bash
        - -c
        - |
          for i in \$(seq 10); do
            timeout 3 bash -c 'exec 3<>/dev/tcp/hatchet-engine.hatchet.svc/7070' 2>/dev/null && echo connected && exit 0
            sleep 1
          done
          echo refused; exit 1
YAML
  until [[ $(kubectl -n "$1" get pod hatchet-tcp-check -o jsonpath='{.status.phase}') =~ Succeeded|Failed ]]; do sleep 2; done
  kubectl -n "$1" logs hatchet-tcp-check
  kubectl -n "$1" delete pod hatchet-tcp-check >/dev/null
}
```

```sh
hatchet_test_ns dispatcher        # a namespace in clientNamespaces
hatchet_tcp_check dispatcher      # connected
hatchet_test_ns hatchet-denied    # not in clientNamespaces
hatchet_tcp_check hatchet-denied  # refused
kubectl delete namespace hatchet-denied
```

Whether Hatchet runs workflows is proven by the dispatcher's worker.

### Rotate a token

```sh
kubectl -n hatchet delete secret hatchet-token-dispatcher
systemctl start hatchet-credentials
```

The client's Secret gets the new token; restart the client. The old
token stays valid until it is revoked in the dashboard (Settings, API
Tokens); `hatchet-admin` has no command for it.

### Remove a client namespace

Remove it from `clientNamespaces` and deploy: NetworkPolicy no longer
admits it, and `hatchet-credentials` deletes the Secrets it labelled
`backfabric.io/hatchet-client=<namespace>`: `hatchet/hatchet-token-<namespace>`
and `<namespace>/hatchet-client-token`. The namespace itself stays: it belongs
to the module that created it. The token stays valid until 2126 (Hatchet issues tenant
tokens for 100 years); revoke it in the dashboard (Settings, API Tokens;
it is named `default`, created at the time in the unit's journal).

## The units

`hatchet-credentials` runs after k3s and `postgres-credentials` at every
deployment and at boot, waits for the k3s API and the namespace (5 minutes
each), and then fails without restarting, so that a deployment reports
it. In order, each step only if its Secret is missing:

1. the admin's password, random, into `hatchet-admin`;
2. a Job `hatchet-setup-keys` running `hatchet-admin k8s quickstart`,
   which writes the encryption keysets and cookie secrets into
   `hatchet-keys`;
3. per client namespace, once the API is ready (it seeds the admin and
   the tenant): a Job `hatchet-setup-token-<namespace>` running
   `hatchet-admin k8s create-worker-token`, which writes a token (valid for
   100 years) into `hatchet-token-<namespace>`.

Then it copies every token into its namespace (skipped, with a log line,
while the namespace does not exist), and
deletes the labelled token Secrets of namespaces no longer listed. The
Jobs run as the service account `hatchet-setup`, which may only create
Secrets in `hatchet` and read or update the ones it writes; they are
deleted after they complete, their logs go to the unit's journal. After
fixing a failure, `systemctl start hatchet-credentials`.

Until `hatchet-keys` exists, the engine and the API wait in
`CreateContainerConfigError`; on the first start they also show
`FailedMount` events ("secret postgres-hatchet not found") until
`postgres-credentials` has written the database's Secret. Both are
transient: the kubelet retries. Both run `hatchet-migrate` as an init
container, which retries its connection for 30 seconds (kube-router
admits a new pod's address a moment after it starts) and migrates under
a lock, so both can run at once.

## Upgrade

The version and the five digests in `nix/modules/hatchet.nix`
(`crane digest ghcr.io/hatchet-dev/hatchet/hatchet-<component>:<version>`);
the build fails on an image without a digest. Read Hatchet's release notes
for migrations that need steps. Deploying replaces the pods; each runs the
migrations first.

## Turning it off

`enable = false` lists `hatchet` in `backfabric.k3s.removedManifests`;
the deployment restarts k3s, which deletes the namespace `hatchet` with
everything in it, including the generated keys, the admin's password and
the tokens. The database entry leaves `backfabric.postgres.databases`.
What stays:

- the database `hatchet` and its role (reclaim policy `retain`), with
  rows encrypted with the deleted keys and the old admin;
- the Secrets `hatchet-client-token` in the client namespaces, with tokens
  no new key accepts (the client namespaces belong to their modules).

Hatchet holds only ids (ADR 0027): the dispatcher's own record is
canonical. So before enabling it again, drop the database, on the host:

```sh
kubectl -n postgres exec platform-1 -c postgres -- psql -c 'DROP DATABASE hatchet WITH (FORCE)'
```

On enable, CloudNativePG creates it again, empty, and
`hatchet-credentials` replaces the client tokens.
