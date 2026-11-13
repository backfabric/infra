// What is on main, what is in review, and what is decided but not built.
// Every entry links the pull requests, issues or decision records it rests on.
const pr = (n) => ({ label: `#${n}`, href: `https://github.com/backfabric/infra/pull/${n}` });
const issue = (n) => ({ label: `#${n}`, href: `https://github.com/backfabric/infra/issues/${n}` });
const adr = (n, slug) => ({ label: `ADR ${n}`, href: `/docs/adr/${n}-${slug}/` });

export default {
  shipped: [
    {
      title: "Encrypted disks",
      text: "LUKS on every system disk, one btrfs across them (raid1 with two or more), GRUB mirrored to every disk for BIOS and UEFI.",
      links: [pr(4), adr("0003", "btrfs-raid1-over-luks")],
    },
    {
      title: "Unlock over SSH",
      text: "The initrd runs its own key-only SSH server; every boot waits for the passphrase.",
      links: [pr(6), adr("0004", "initrd-ssh-unlock")],
    },
    {
      title: "Closed hosts",
      text: "Root SSH with keys only, the one open port in nftables; no ping replies, IPv4 only.",
      links: [pr(6), pr(33), pr(40), adr("0018", "key-only-ssh-without-hiding")],
    },
    {
      title: "Secrets with sops-nix",
      text: "Hosts decrypt with their SSH host key; .sops.yaml is maintained by commands.",
      links: [pr(8), pr(12)],
    },
    {
      title: "The backfabric command",
      text: "keygen, probe, install, unlock, finalize, deploy: steps that can be run again, in a dev shell.",
      links: [pr(10), pr(14), pr(18), pr(29)],
    },
    {
      title: "Private repository template",
      text: "nix flake init -t github:backfabric/infra, with direnv.",
      links: [pr(16), pr(25)],
    },
    {
      title: "Hardened k3s",
      text: "Embedded etcd, the CIS hardening guide, Pod Security restricted, an audit log, secretbox, no NodePort or LoadBalancer; k3s 1.36.",
      links: [pr(37), pr(50), adr("0017", "cluster-hardening-defaults")],
    },
    {
      title: "OpenBao on the host",
      text: "Raft storage, static seal, TLS only, Kubernetes auth, every request audited.",
      links: [pr(42), adr("0009", "openbao-on-host-with-eso")],
    },
    {
      title: "Audit telemetry",
      text: "An OpenTelemetry Collector on the host writes the audit archive of record.",
      links: [pr(46), adr("0021", "audit-telemetry-collector-on-host")],
    },
    {
      title: "Agent image",
      text: "Codex behind an A2A 1.0 supervisor, built by Nix, published to ghcr.io/backfabric/agent with build provenance.",
      links: [pr(54), pr(58), pr(82), adr("0022", "ci-builds-the-agent-image")],
    },
    {
      title: "Clean switch-off",
      text: "Turning a subsystem off removes its manifests and the objects k3s applied from them.",
      links: [pr(56)],
    },
    {
      title: "Pinned exemptions",
      text: "Namespaces that skip Pod Security may run digest-pinned images only.",
      links: [pr(66), adr("0024", "pod-security-exemptions-for-pinned-images")],
    },
    {
      title: "Agent Substrate runtime",
      text: "Agents as actors in gVisor sandboxes on warm worker pods, suspended to snapshots between tasks and resumed on the next request.",
      links: [pr(48), adr("0023", "agent-substrate-runtime")],
    },
    {
      title: "Platform PostgreSQL",
      text: "One PostgreSQL in the cluster for platform services, run by CloudNativePG; no backups yet.",
      links: [pr(68), adr("0025", "platform-postgres-with-cloudnativepg")],
    },
  ],
  inProgress: [
    {
      title: "Design of the dispatcher",
      text: "The record of the single A2A entry point for agent tasks, a Go service, before any of its code.",
      links: [pr(80), issue(79)],
    },
    {
      title: "Agents speak A2A",
      text: "The agent image serves A2A 1.0: one actor is one session, one task at a time.",
      links: [pr(82), issue(81)],
    },
    {
      title: "Task queue with Hatchet",
      text: "Hatchet in the cluster, on the platform PostgreSQL, as the queue behind the dispatcher.",
      links: [pr(84), issue(83)],
    },
  ],
  planned: [
    {
      title: "External Secrets Operator",
      text: "Syncs values from OpenBao into ordinary Kubernetes Secrets, so pods consume them unchanged.",
      links: [adr("0009", "openbao-on-host-with-eso")],
    },
    {
      title: "Pull deploys with comin",
      text: "Hosts deploy their own commits, with a last-known-good rollback.",
      links: [adr("0014", "pull-deploy-with-comin")],
    },
    {
      title: "More nodes",
      text: "Joining further servers to the embedded etcd cluster.",
      links: [adr("0006", "k3s-embedded-etcd-from-day-one")],
    },
  ],
};
