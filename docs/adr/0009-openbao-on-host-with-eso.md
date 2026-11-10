# Workload secrets in OpenBao on the host, synced by External Secrets Operator

Secrets for workloads (agents) live in OpenBao, written at runtime rather than committed, while sops keeps only host bootstrap and long-lived secrets (loaded into OpenBao at deployment). OpenBao runs as a NixOS service on the host, not in the cluster, so it does not depend on cluster health and is configured as code (mounts, policies, Kubernetes auth by an idempotent oneshot, initialised automatically, static seal). External Secrets Operator syncs values into ordinary Kubernetes Secrets, so pods consume them unchanged; the copies in etcd are encrypted by k3s secrets encryption (`secretbox`). Not implemented yet.

## Considered Options

- HashiCorp Vault: BSL-licensed and unfree in nixpkgs; OpenBao (MPL-2.0) is API-compatible.
- Manual unseal: every reboot already waits for the LUKS passphrase; the static seal key in sops gives the same trust as root on the host.
- CSI driver or OpenBao agents in pods: keep secrets out of etcd but are not plain Secrets; KMS v2 providers for OpenBao are still previews.
