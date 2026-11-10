# Cluster hardening defaults

The `k3s` subsystem keeps everything in the cluster unreachable from outside and records what happens in it, using only upstream k3s, Kubernetes, and NixOS options. NixOS's firewall filters only traffic addressed to the host (input). kube-proxy DNATs NodePorts and Service externalIPs in PREROUTING to pod IPs, and the portmap CNI plugin does the same for hostPorts, so that traffic is forwarded and the input chain never sees it. For that reason:

- NodePorts only answer on loopback (kube-proxy `nodeport-addresses=127.0.0.0/8`).
- The `DenyServiceExternalIPs` admission plugin rejects Services with externalIPs. It is appended to k3s's own admission plugins (`enable-admission-plugins+=`, which keeps NodeRestriction).
- Pod Security Admission enforces `baseline` in every namespace except kube-system, where k3s's own components run, and audits and warns at `restricted`. Baseline rejects privileged, hostNetwork, hostPID, hostPath, and hostPort pods, which would otherwise reach around the firewall or into the host.
- SSH is open only on the uplink. network.nix names that interface `uplink` with a systemd .link unit matched by MAC. Before, the SSH port was open on every interface, including the flannel bridge `cni0`, so every pod could reach sshd. Pods reach only the API server on the host (port 6443 on `cni0`). The name is set by udev when the device appears, already in the initrd, so it changes with the next boot, not on `switch` or `test`.
- The API server audits every request at level `Metadata`, without request or response bodies, so Secret values never reach the log. The log goes to `/var/log/kubernetes/audit.log` (directory mode 0700, file mode 0600) in the API server's default `blocking` mode and is rotated by the API server: at 100 MB, keeping 30 gzipped files for at most 90 days. It is not sent to journald (`audit-log-path=-`): there it would be mixed into the k3s log and subject to journald's per-service rate limit, which drops messages.
- The system images (CoreDNS, pause, the Helm job) come from the k3s package's airgap archive for the host's platform, imported by k3s from `/var/lib/rancher/k3s/agent/images`. The cluster then does not depend on a registry to start, and the images are pinned with the package.

## Recorded constraints

- The server token is in `secrets/common.yaml`, which every host can read. With one server that does not matter. Before the first agent joins, the server token moves to a sops file only the servers can read, and agents get a separate agent token (`services.k3s.agentTokenFile`).
- A new node joins with the full token from `/var/lib/rancher/k3s/server/token` on the first server (`K10<CA hash>::server:<secret>`), which pins the cluster CA. The bare secret alone would trust whatever CA the server address presents.
- etcd snapshots encrypt only Secrets (secretbox). Everything else in them is plaintext, and the bootstrap data in them (certificates, the Secrets encryption key) is protected only by the server token. Backups that leave the host must be encrypted as a whole.

## Considered Options

- `networking.firewall.filterForward`: its forward-allow chain accepts every DNATed connection (`ct status dnat accept`), so it would not stop NodePorts.
- `trustedInterfaces = [ "cni0" ]`: opens every host port to every pod.
- Audit log to journald: see above.
