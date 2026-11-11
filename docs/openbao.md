# OpenBao

The `openbao` subsystem runs [OpenBao](https://openbao.org/) on every
server, as the upstream NixOS service `services.openbao` (ADR 0009). It
needs no manual step: it unseals itself, is initialised once, and its
configuration is applied from Nix on every deployment.

| What | Where |
| ---- | ----- |
| Data (raft) | `/var/lib/openbao` (`/var/lib/private/openbao`, dynamic user) |
| Root token, recovery key | `/var/lib/openbao-init/root-token`, `init.json` (root, dir 0700, files 0400) |
| Raft snapshots | `/var/lib/openbao-snapshots` (root, 0700), daily, the last 14 |
| Audit log | `/var/log/openbao/audit.log` (root only), rotated daily, 30 kept |
| Listeners | `https://127.0.0.1:8200`, `https://<node address>:8200` (open only on `cni0`) |
| Pods | `https://openbao.openbao.svc:8200` |

## Units

- `openbao.service`: the server. Static seal with `openbao-seal-key`; TLS
  with `openbao-tls-key` and `openbao-tls-cert`; all three from
  `secrets/common.yaml`, passed to the dynamic user with systemd
  credentials. Upstream sets `restartIfChanged = false`: a deployment that
  changes its configuration does not restart it; run
  `systemctl restart openbao` (it unseals itself). A new TLS certificate
  from sops restarts it.
- `openbao-init.service`: if OpenBao is not initialised, runs
  `bao operator init` (with the static seal: one recovery key, no unseal
  keys) and writes the output to `/var/lib/openbao-init/init.json` and the
  root token to `root-token`. The root token is kept, not revoked.
- `openbao-config.service`: after `openbao-init` and k3s, and on every
  deployment that changes it: the KV v2 mount `secret/`, the Kubernetes
  auth method `kubernetes/` (against `https://127.0.0.1:6443` with k3s's
  server CA), the policies `backfabric.openbao.policies`, the roles
  `backfabric.openbao.kubernetesRoles` (policies and roles not declared are
  deleted), and the permanent secrets `backfabric.openbao.kv.secrets` from
  sops (written only when they differ). Both oneshots are restarted by
  systemd until they succeed.
- `openbao-snapshot.timer`: daily `bao operator raft snapshot save`.

## Using `bao` on the host

`BAO_ADDR` (`https://127.0.0.1:8200`) and `BAO_CACERT`
(`/run/secrets/openbao-ca-cert`) are set for every shell. As root:

```sh
export BAO_TOKEN=$(cat /var/lib/openbao-init/root-token)
bao status
bao kv get secret/example/app
```

## Kubernetes auth

OpenBao runs outside the cluster and has no reviewer token: it reviews a
client's service account token with that token itself (ADR 0019). Each
service account that logs in therefore needs the ClusterRole
`system:auth-delegator`, besides a role in `kubernetesRoles`.

## TLS

`backfabric keygen` generates a CA (ECDSA P-256, 10 years) and a server
certificate (ECDSA P-256, 3 years) for `openbao.openbao.svc`,
`openbao.openbao.svc.cluster.local` and `127.0.0.1`. Clients trust the CA,
`openbao-ca-cert`. Check the certificate on the host:

```sh
openssl s_client -connect 127.0.0.1:8200 -CAfile /run/secrets/openbao-ca-cert </dev/null 2>/dev/null |
  openssl x509 -noout -ext subjectAltName -enddate
```

To issue a new server certificate (before it expires; clients keep
trusting the CA), in the dev shell:

```sh
sops unset secrets/common.yaml '["openbao-tls-key"]'
sops unset secrets/common.yaml '["openbao-tls-cert"]'
backfabric keygen
git commit secrets/common.yaml -m "chore: renew OpenBao's TLS certificate"
backfabric deploy node1
```

The deployment restarts OpenBao with the new certificate.

## Audit log

Every request and response is written to `/var/log/openbao/audit.log`, one
JSON object per line, with secret values HMACed. If OpenBao cannot write
the log, it refuses requests. logrotate rotates it daily and keeps 30
files; OpenBao reopens the file on SIGHUP (`systemctl reload openbao`).

## Snapshots and restore

A snapshot contains the encrypted data; restoring it needs the same seal
key. They are on the host's disks only: copies that leave the host are a
backup's job. To take one now: `systemctl start openbao-snapshot`.

To restore on the same host (as root, with `BAO_TOKEN` as above):

```sh
bao operator raft snapshot restore /var/lib/openbao-snapshots/openbao-<time>.snap
```

The root token in `/var/lib/openbao-init` stays valid when the snapshot was
taken on this host. To start over with empty storage instead, stop
`openbao`, move `/var/lib/private/openbao` and `/var/lib/openbao-init` away,
and start `openbao-init` and `openbao-config` again; `openbao-init` refuses
to overwrite the token and recovery key of an earlier initialisation.

## Seal key

`openbao-seal-key` must never change: OpenBao cannot unseal its data, or a
snapshot, without it. It is shared by every server of a future raft cluster.
Like the k3s token, it moves to a servers-only sops file before the first
agent joins (ADR 0017).
