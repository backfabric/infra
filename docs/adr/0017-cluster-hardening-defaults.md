# Cluster hardening defaults

The `k3s` subsystem follows the [K3s CIS hardening guide](https://docs.k3s.io/security/hardening-guide) ("v1.29 and Newer"), so the cluster's hardening is the documented, benchmarked one rather than our own. The guide's settings are applied unchanged: `protect-kernel-defaults` with the guide's kernel parameters, Secrets encryption, the admission plugins `NodeRestriction` and `EventRateLimit`, Pod Security Admission `restricted` (enforce, audit, warn) with kube-system exempt, the audit policy at level `Metadata` with the log in `/var/lib/rancher/k3s/server/logs` (mode 0700, 30 days, 10 files of 100 MB), `service-account-extend-token-expiration=false`, `terminated-pod-gc-threshold=100`, and the kubelet's `streaming-connection-idle-timeout` and TLS cipher suites. Only upstream options are used: `services.k3s` options where the NixOS module has them, k3s flags otherwise, and the policy files in the Nix store.

## Deviations and additions

- Secrets encryption uses the `secretbox` provider instead of k3s's default `aescbc`.
- EventRateLimit uses the example limits of the Kubernetes documentation; the guide leaves the values to the operator.
- `DenyServiceExternalIPs` is enabled: it is Kubernetes' recommended mitigation for CVE-2020-8554, and kube-proxy would otherwise expose a Service's externalIPs.
- A ValidatingAdmissionPolicy, deployed from the k3s manifests directory as the guide deploys policies, rejects Services of type NodePort and LoadBalancer. kube-proxy DNATs them in PREROUTING to pod IPs, so that traffic is forwarded and never meets the host's input firewall. k3s's own Services are ClusterIP. hostPort is covered by Pod Security `restricted`.
- System images come from the k3s package's airgap archive for the host's platform, so the cluster does not depend on a registry to start, and the images are pinned with the package.
- The host firewall opens only port 6443 on `cni0`, which pods need to reach the API server through the `kubernetes` Service. k3s's documentation for firewalled hosts trusts the whole pod and service CIDRs instead; that would let every pod reach every port of the host.
- Not applied:
  - the guide's manual or permissive controls: PKI file permissions (a manual chmod of files k3s manages), `AlwaysPullImages` (contradicts the airgap images), `request-timeout` (the benchmark advises the default), `pod-max-pids` (no value fits every workload yet), and the patches of the default service accounts (manual `kubectl patch`, done with the workloads);
  - the per-namespace NetworkPolicies, which come with the workloads.
- Known gap, tracked in the backlog: the SSH port is open on every interface, including `cni0`, so pods can reach the host's sshd.

## Recorded constraints

- The server token is in `secrets/common.yaml`, which every host can read. With one server that does not matter. Before the first agent joins, the server token moves to a sops file only the servers can read, and agents get a separate agent token (`services.k3s.agentTokenFile`).
- A new node joins with the full token from `/var/lib/rancher/k3s/server/token` on the first server (`K10<CA hash>::server:<secret>`), which pins the cluster CA. The bare secret alone would trust whatever CA the server address presents.
- etcd snapshots encrypt only Secrets. Everything else in them is plaintext, and the bootstrap data in them (certificates, the Secrets encryption key) is protected only by the server token. Backups that leave the host must be encrypted as a whole.
