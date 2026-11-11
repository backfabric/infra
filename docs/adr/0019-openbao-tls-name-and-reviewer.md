# OpenBao's TLS name and Kubernetes token review

OpenBao on the host (ADR 0009) serves TLS only, with a server certificate for a fixed name, `openbao.openbao.svc` (and `openbao.openbao.svc.cluster.local`), plus 127.0.0.1, signed by a CA of its own. `backfabric keygen` generates the CA and the certificate as cluster-wide secrets, the CA certificate and the server key and certificate in `secrets/common.yaml` and the CA key in `secrets/admin.yaml`, which only the admins can decrypt, so the certificate does not depend on a host's address and `keygen` needs no host. Pods reach OpenBao by that name through a Service without selector in namespace `openbao`, whose EndpointSlice points at the node address, deployed from the k3s manifests directory; the firewall opens port 8200 only on `cni0`, as for the API server (ADR 0017). The Kubernetes auth method has no reviewer token: OpenBao reviews each client's service account token with that token itself, so OpenBao stores no Kubernetes credential, and each client's service account needs the ClusterRole `system:auth-delegator`.

## Considered Options

- A certificate with the node address: ties the certificate to the host, and `keygen` would need the host's configuration.
- OpenBao's built-in or cert-manager certificates: the CA must be known before the cluster exists, and the host must serve TLS before any workload runs.
- A long-lived reviewer token in OpenBao: one more credential to store and rotate, and every token review would run with its rights.

## Consequences

- Clients outside the cluster's DNS (on the host) use 127.0.0.1; other hosts of a future cluster would need the name resolved or a new certificate.
- The server key is in `secrets/common.yaml` with the seal key, readable by every host; both move to a servers-only file before the first agent joins (ADR 0017). The CA key is never on a host.
- The server certificate is valid for 3 years and the CA for 10; a new server certificate is issued by removing it from `secrets/common.yaml` and running `backfabric keygen` (docs/openbao.md).
