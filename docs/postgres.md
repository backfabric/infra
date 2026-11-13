# Platform PostgreSQL

The `postgres` subsystem runs one PostgreSQL for the platform services in
the cluster, with the [CloudNativePG](https://cloudnative-pg.io/) operator
(ADR 0025). It is off by default:

```nix
backfabric.postgres = {
  enable = true;
  storageSize = "20Gi"; # the default
  databases = [
    { name = "a2a"; owner = "a2a"; namespace = "a2a"; }
  ];
};
```

| What | Where |
| ---- | ----- |
| Operator | Deployment `cnpg-controller-manager` in `cnpg-system` (k3s manifest `postgres-operator`) |
| Cluster | `platform` in `postgres`, one instance, pod `platform-1` (k3s manifest `postgres`) |
| Data | `/var/lib/postgres-platform` on the host (uid 26, 0700), PersistentVolume `postgres-platform`, claim `postgres/platform-1` |
| Service | `platform-rw.postgres.svc:5432`, TLS (CloudNativePG's CA, Secret `postgres/platform-ca`) |
| Role passwords | Secret `postgres/postgres-role-<owner>` (`_` as `-`) |
| A service's credentials | Secret `<namespace>/postgres-<database>` (`_` as `-`) |

## Status

On the host, as root:

```sh
kubectl -n postgres get cluster,database,pod,pvc
kubectl -n cnpg-system get deployment
kubectl -n postgres describe cluster platform     # events, conditions
systemctl status postgres-credentials             # last copy of the credentials
```

The cluster is ready when `get cluster` shows `Cluster in healthy state`
and `READY 1`. CloudNativePG's kubectl plugin shows more (replication, WAL,
certificates); nixpkgs packages it, possibly a version behind the
operator:

```sh
nix shell nixpkgs#kubectl-cnpg -c kubectl-cnpg -n postgres status platform
```

`psql` as the superuser, over the pod's local socket (network logins of
`postgres` are disabled):

```sh
kubectl -n postgres exec -it platform-1 -c postgres -- psql
```

## Connect as a service

For each entry of `databases`, the role `owner` logs in to the database
`name`, and only to it (pg_hba: `hostssl <name> <owner> all
scram-sha-256` per database, then `host all all all reject`: no other
role, database, or connection without TLS), from pods in `namespace` only
(NetworkPolicy; every other namespace is denied, and so is the rest of
`postgres`; in `cnpg-system`, only the operator's webhook is reachable). The Secret
`postgres-<name>` in that namespace has `host`, `port`, `dbname`,
`username`, `password` and `ca.crt`. Connect with `sslmode=verify-full`
against `ca.crt`; mount the Secret as a volume rather than reading
`ca.crt` into an environment variable: CloudNativePG renews its CA every
83 days, and `postgres-credentials` copies the new one within a day.

Clients must retry connecting at startup. kube-router admits a new pod's
address to PostgreSQL only once it has added it to the NetworkPolicy's
set of allowed sources, a moment after the pod starts, and rejects its
packets until then: a connection in the pod's first second can fail with
"Connection refused", and one a second later succeeds. A connection from a
namespace that is not in `databases` always fails this way. For libpq
clients:

```yaml
env:
  - { name: PGHOST, valueFrom: { secretKeyRef: { name: postgres-a2a, key: host } } }
  - { name: PGPORT, valueFrom: { secretKeyRef: { name: postgres-a2a, key: port } } }
  - { name: PGDATABASE, valueFrom: { secretKeyRef: { name: postgres-a2a, key: dbname } } }
  - { name: PGUSER, valueFrom: { secretKeyRef: { name: postgres-a2a, key: username } } }
  - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: postgres-a2a, key: password } } }
  - { name: PGSSLMODE, value: verify-full }
  - { name: PGSSLROOTCERT, value: /run/postgres/ca.crt }
volumeMounts:
  - { name: postgres, mountPath: /run/postgres, readOnly: true }
# volumes:
#   - { name: postgres, secret: { secretName: postgres-a2a, items: [ { key: ca.crt, path: ca.crt } ] } }
```

### Test a connection

On the host, as root, from a pod that passes Pod Security `restricted`, in
the service's namespace (here `a2a`, Secret `postgres-a2a`):

```sh
cat >/tmp/psql.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: psql, namespace: NS }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 26, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: psql
      image: ghcr.io/cloudnative-pg/postgresql:18.6-minimal-trixie@sha256:ec2ed3404e89fff99643901b58a2a34c46a46345fe69a3d96500b82f995c327b
      # Retries for up to 30 s: see "Clients must retry" above.
      command:
        - sh
        - -c
        - |
          for i in $(seq 30); do
            psql -c "select current_user, current_database(), ssl from pg_stat_ssl where pid = pg_backend_pid()" && exit 0
            sleep 1
          done
          exit 1
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
      env:
        - { name: PGHOST, valueFrom: { secretKeyRef: { name: SECRET, key: host } } }
        - { name: PGDATABASE, valueFrom: { secretKeyRef: { name: SECRET, key: dbname } } }
        - { name: PGUSER, valueFrom: { secretKeyRef: { name: SECRET, key: username } } }
        - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: SECRET, key: password } } }
        - { name: PGSSLMODE, value: verify-full }
        - { name: PGSSLROOTCERT, value: /run/postgres/ca.crt }
        - { name: PGCONNECT_TIMEOUT, value: "5" }
      volumeMounts: [ { name: pg, mountPath: /run/postgres, readOnly: true } ]
  volumes: [ { name: pg, secret: { secretName: SECRET, items: [ { key: ca.crt, path: ca.crt } ] } } ]
YAML
```

```sh
sed 's/NS/a2a/; s/SECRET/postgres-a2a/g' /tmp/psql.yaml | kubectl apply -f -
kubectl -n a2a wait --for=jsonpath='{.status.phase}'=Succeeded pod/psql --timeout=90s
kubectl -n a2a logs psql      # a2a | a2a | t
kubectl -n a2a delete pod psql
```

From a namespace not in `databases`, with a copy of the Secret, every
attempt fails with "Connection refused" and the pod ends `Failed` after
about 30 seconds.

## Add a database

Add an entry to `databases` and deploy. k3s applies the new `Database` and
role; `postgres-credentials` generates the role's password and writes the
service's Secret (creating the namespace if it does not exist). Several
databases may share an owner. Removing an entry keeps the database (reclaim
policy `retain`), the role and both Secrets; drop them with `psql` (above)
and `kubectl delete secret`.

The volume's size (`storageSize`) is fixed once the claim exists:
CloudNativePG does not resize it (`resizeInUseVolumes: false`), and it is
not enforced either (a directory on the host's file system).

A password is generated once. To rotate one, delete
`postgres/postgres-role-<owner>` and run `systemctl start
postgres-credentials`: CloudNativePG sets the new password, and the
service's Secret gets it (restart the service if it read it at start).

## The units

`postgres-credentials` runs after k3s at every deployment, at boot and
daily. It waits for the k3s API and the namespace `postgres` (5 minutes
each) and for the cluster's CA (10 minutes: the first start pulls the
images), and then fails, without restarting, so that a deployment reports
it. `journalctl -u postgres-credentials` says what it waited for; after
fixing the cause, `systemctl start postgres-credentials`.

k3s applies `postgres-operator` (the CRDs and the operator) before
`postgres`; until the operator's webhook answers, applying the Cluster
fails and k3s retries every 15 seconds (`journalctl -u k3s | grep
postgres`, `kubectl -n kube-system get addon postgres -o yaml`).

## Backups

None yet: losing the host's disks or `/var/lib/postgres-platform` loses
every platform service's data. The plan is CloudNativePG's Barman Cloud
plugin, writing base backups and WAL to an S3 store (RustFS), once
cert-manager is in the cluster (the plugin needs it). Until then, a
consistent copy of each database by hand, on the host as root (over the
pod's local socket, as the superuser):

```sh
install -d -m 0700 /root/postgres-dumps
for db in a2a hatchet; do   # the names in `databases`
  kubectl -n postgres exec platform-1 -c postgres -- pg_dump -Fc -d "$db" >"/root/postgres-dumps/$db.dump"
done
```

Restore one into the (empty) database CloudNativePG created for it,
owned by its owner:

```sh
kubectl -n postgres exec -i platform-1 -c postgres -- \
  pg_restore -d a2a --no-owner --role=a2a --clean --if-exists </root/postgres-dumps/a2a.dump
```

## Turning it off

**Dump every database first** (see [Backups](#backups)): turning the
subsystem off and on again does not bring the data back.

`enable = false` lists `postgres` and `postgres-operator` in
`backfabric.k3s.removedManifests`; the deployment restarts k3s, which
deletes what it applied from them: the operator, `cnpg-system`, its
webhooks, and the CRDs (and with them any CloudNativePG object anywhere in
the cluster); the namespace `postgres` with the Cluster, its pod, claim
and Secrets; the PersistentVolume. What stays:

- the files in `/var/lib/postgres-platform` (reclaim policy Retain);
- the Secrets `postgres-<database>` in the services' namespaces, and
  namespaces `postgres-credentials` created.

Enabling it again creates a new Cluster and claim, and CloudNativePG
bootstraps a new, empty cluster with initdb: it does not adopt an existing
data directory. It renames a valid one to `pgdata_<timestamp>` next to the
new `pgdata` (an invalid one is deleted). CloudNativePG has no supported
way to bootstrap from an existing data directory; its alternatives
(recovery from a backup or a volume snapshot) need backups this subsystem
does not have yet. So restore the dumps, as in [Backups](#backups), after
`postgres-credentials` has run (`postgres-credentials` sets new passwords).
Every off and on cycle leaves one more `pgdata_<timestamp>` that counts
against the disk; delete them once the restore is checked.

Without a dump, the old directory is the only copy. Recovering from it by
hand (not tested here): hibernate the cluster, which stops its pod but
keeps the claim, swap the directories, and wake it:

```sh
kubectl -n postgres annotate cluster platform --overwrite cnpg.io/hibernation=on
kubectl -n postgres get pod platform-1   # wait until it is gone
cd /var/lib/postgres-platform
mv pgdata pgdata_empty && mv pgdata_<timestamp> pgdata
kubectl -n postgres annotate cluster platform --overwrite cnpg.io/hibernation=off
```

The old directory brings its own roles and password hashes; delete the
`postgres-role-*` Secrets and run `systemctl start postgres-credentials`
so that CloudNativePG sets passwords that match the services' Secrets.
After a re-enable, `pgdata_<timestamp>` has mode 2770, not 0700, because
the kubelet applied the pods' fsGroup (26) to the whole volume. The
instance manager resets the data directory's permissions before it starts
PostgreSQL, so a directory moved back to `pgdata` still starts. Delete it
once it is no longer needed.

After the deployment, check that the CRDs are gone before enabling it
again:

```sh
kubectl get crd | grep cnpg.io   # nothing
```

A CRD can stay `Terminating` (seen with `imagecatalogs.postgresql.cnpg.io`:
condition `InstanceDeletionFailed`, "could not list instances: storage is
(re)initializing"). k3s deletes the removed manifest's objects about 2
seconds after it restarts, and the API server then did not retry the
CRD's deletion for minutes. While a CRD is `Terminating`, enabling the
subsystem again fails to apply the CRDs. Any update to the CRD makes the
API server retry, and it is gone within seconds:

```sh
kubectl get crd -o name | grep cnpg.io |
  xargs -r -I{} kubectl annotate {} --overwrite backfabric.io/touch="$(date +%s)"
```

The `Database` objects carry a finalizer that CloudNativePG removes when
their Cluster is deleted. k3s removes `postgres-operator` before
`postgres` (file name order); if the operator is gone first, the namespace
stays `Terminating`; remove the finalizers by hand:

```sh
kubectl -n postgres get database -o name |
  xargs -r kubectl -n postgres patch --type merge -p '{"metadata":{"finalizers":null}}'
```

Remove the data with `rm -rf /var/lib/postgres-platform` on the host.
