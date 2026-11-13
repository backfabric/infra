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
the Hatchet SDK's settings from the Secret `hatchet-client-token`:

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

### Smoke test

A real worker and a run, with the Python SDK, in a client namespace (here
`dispatcher`). The pod installs the SDK from PyPI, so the namespace needs
egress to the internet.

```sh
cat >/tmp/hatchet-smoke.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: hatchet-smoke, namespace: dispatcher }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: worker
      image: docker.io/library/python:3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
      envFrom: [ { secretRef: { name: hatchet-client-token } } ]
      env: [ { name: HOME, value: /tmp }, { name: PYTHONPATH, value: /tmp/py:/tmp } ]
      command:
        - sh
        - -c
        - |
          pip install -q --target /tmp/py hatchet-sdk==1.45.1
          cat >/tmp/smoke.py <<'PY'
          from hatchet_sdk import Context, EmptyModel, Hatchet
          hatchet = Hatchet()
          @hatchet.task(name="smoke")
          def smoke(input: EmptyModel, ctx: Context) -> dict:
              return {"ok": True}
          if __name__ == "__main__":
              hatchet.worker("smoke-worker", workflows=[smoke]).start()
          PY
          exec python /tmp/smoke.py
YAML
kubectl apply -f /tmp/hatchet-smoke.yaml
kubectl -n dispatcher wait --for=condition=Ready pod/hatchet-smoke --timeout=180s
until kubectl -n dispatcher exec hatchet-smoke -- test -f /tmp/smoke.py; do sleep 2; done   # pip install
kubectl -n dispatcher exec hatchet-smoke -- python -c 'from smoke import smoke; print(smoke.run())'
# {'ok': True}  (the run is queued until the worker has registered)
kubectl -n dispatcher delete pod hatchet-smoke
```

The run and the worker `smoke-worker` appear in the dashboard.

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
and `<namespace>/hatchet-client-token`. The namespace itself stays (it may
have been created by `hatchet-credentials`; delete it by hand if nothing
else uses it). The token stays valid until 2126 (Hatchet issues tenant
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

Then it copies every token into its namespace (created if missing), and
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
  no new key accepts, and the client namespaces themselves (also those
  `hatchet-credentials` created).

Hatchet holds only ids (ADR 0027): the dispatcher's own record is
canonical. So before enabling it again, drop the database, on the host:

```sh
kubectl -n postgres exec platform-1 -c postgres -- psql -c 'DROP DATABASE hatchet WITH (FORCE)'
```

On enable, CloudNativePG creates it again, empty, and
`hatchet-credentials` replaces the client tokens.
