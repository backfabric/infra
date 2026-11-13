# backfabric/infra

NixOS modules for running an encrypted k3s cluster on Hetzner bare metal,
intended as the substrate for running agents.

This flake is public and contains no host-specific data. Concrete hosts, IP
addresses, and secrets live in a separate private repository that consumes
these modules.

Status: work in progress. Project website: <https://backfabric.dev>.

## Layout

All Nix code lives under `nix/`, so that other parts of the project can sit
beside it later. Only `flake.nix` and `flake.lock` stay at the root: Nix
requires them there for the flake to be `github:backfabric/infra`.

- `nix/modules/<subsystem>.nix`: one NixOS module per subsystem, with options
  under `backfabric.<subsystem>`. Each subsystem is registered in
  `nix/modules/default.nix` and exported as `nixosModules.<subsystem>`. The
  registry is a function of the flake inputs, so an entry also imports the
  NixOS modules of the inputs its subsystem needs (e.g. disko for `disks`);
  consumers only import modules from this flake.
- `nixosModules.default` imports every subsystem module.
- `nix/packages/`: what subsystem modules deploy and build from upstream
  releases, e.g. Agent Substrate (patched manifests, images) and
  CloudNativePG's manifest with its images pinned by digest.
- `nix/fleet/`: the fleet dev shell for the operator machine,
  `lib.mkFleetShell { pkgs, nixosConfigurations }`, with a generated SSH
  config and the operator command `backfabric` (`nix/fleet/cli/`; subcommands
  `sops init`, `keygen`, `sops add-host`, `probe`, `install`, `unlock`,
  `finalize`, `deploy`; also `packages.<system>.backfabric`, the default package), see
  [docs/fleet-shell.md](docs/fleet-shell.md) and
  [docs/secrets.md](docs/secrets.md).
- `nix/examples/single-node/`: an example host with two disks and an excerpt of
  a facter report, evaluated by `checks.x86_64-linux.example-single-node`,
  and with one disk by `checks.x86_64-linux.example-single-disk`; its fleet
  dev shell is `devShells.<system>.example-fleet`. The `assertions-*` checks
  evaluate the assertions that compare a configuration with its facter
  report: none fails for the example, and a report without a network driver
  or without a configured disk fails the expected one.
- `nix/templates/default/`: the skeleton of the private repository, see below;
  evaluated by `checks.x86_64-linux.template-empty` and
  `checks.x86_64-linux.template-with-host`.
- `nix/images/`: the agents' container image `ghcr.io/backfabric/agent`
  (Codex and an HTTP supervisor, run as an Agent Substrate actor),
  `packages.x86_64-linux.agent-image`, built and published by CI, see
  [docs/agent-image.md](docs/agent-image.md).
- `website/`: the project website at <https://backfabric.dev> (Eleventy),
  generated from this README, the template's README, and `docs/`;
  `packages.<system>.website` (`nix/website.nix`), published to GitHub
  Pages by CI ([ADR 0026](docs/adr/0026-project-website-in-the-repository.md)).
- `docs/`: operational runbooks:
  [the fleet dev shell and installing a host](docs/fleet-shell.md),
  [replacing a failed disk](docs/disk-replacement.md),
  [unlocking the disks over SSH](docs/initrd-unlock.md),
  [managing secrets](docs/secrets.md),
  [OpenBao](docs/openbao.md),
  [the audit telemetry collector](docs/otel.md),
  [the platform PostgreSQL](docs/postgres.md),
  [the agent image](docs/agent-image.md),
  [Agent Substrate](docs/substrate.md);
  architectural decisions in [docs/adr/](docs/adr/).

## Private repository

Create the private repository from the template, then follow its README
(sops setup, adding and installing a host, unlocking, updating):

```sh
mkdir fleet && cd fleet
nix flake init -t github:backfabric/infra
```

## Subsystems

- `disks`: per system disk a BIOS boot partition, an ESP, and a LUKS
  partition; one btrfs file system across all disks, raid1 with two or more
  (subvolumes `@` for `/`, `@nix` for `/nix`); GRUB mirrored to every disk
  for BIOS and UEFI boot. Set
  `backfabric.disks.devices` to the `/dev/disk/by-id/...` paths of the
  system disks (`backfabric probe` lists them); evaluation fails unless each
  is a disk in the host's facter report. `backfabric install` passes the
  LUKS passphrase from `backfabric keygen` to nixos-anywhere with
  `--disk-encryption-keys /tmp/disk-encryption.key <file>`.
- `network`: static IPv4 on the uplink, matched by MAC address, with
  systemd-networkd, in the booted system and in the initrd; IPv6 is
  disabled. Set `backfabric.network.macAddress`, `ipv4.address`, and
  `ipv4.gateway` from the Hetzner Robot; `nameservers` (Hetzner's IPv4
  resolvers) has a default. The
  initrd network driver comes from nixos-facter: set
  `hardware.facter.reportPath` to the host's report (e.g. `./facter.json`),
  which `backfabric probe` generates. Evaluation fails without a network
  controller with a driver in it. Facter reports contain no MAC addresses,
  so `backfabric probe` and `install` check on the server that the MAC
  exists and its driver is in the initrd.
- `access`: root login with SSH keys only on `backfabric.access.ssh.port`,
  the only port open from outside in the (nftables) firewall; no ping
  replies. The initrd
  runs an SSH server on `backfabric.access.initrdSsh.port` to unlock the
  disks, see [docs/initrd-unlock.md](docs/initrd-unlock.md). Set
  `authorizedKeys`, both ports, and the public host keys
  `hostKey.publicKey` and `initrdSsh.publicKey` from the `.pub` files
  `backfabric keygen` writes next to the facter report.
- `secrets`: sops-nix, decrypting with the SSH ed25519 host key
  (`/etc/ssh/ssh_host_ed25519_key`) only. Set
  `backfabric.secrets.commonFile` to `secrets/common.yaml`, the sops file
  of the cluster-wide secrets that `backfabric keygen` creates and fills,
  and `sops.defaultSopsFile` to the host's own file once it has one; other
  subsystems declare their own `sops.secrets.*`. `backfabric install` copies
  the host key with nixos-anywhere `--extra-files` so the first boot can
  decrypt, see [docs/secrets.md](docs/secrets.md).
- `k3s`: the first k3s server of the cluster, on embedded etcd
  (`clusterInit`), with the cluster token `k3s-token` from
  `backfabric.secrets.commonFile` (generated by `backfabric keygen`; never
  change it, an etcd snapshot is only restored with its cluster's token).
  IPv4-only on k3s's default CIDRs (pods 10.42.0.0/16, services
  10.43.0.0/16), flannel (vxlan) and the embedded NetworkPolicy controller;
  traefik, servicelb, metrics-server, and local-storage disabled, the other
  system images from the package's airgap archive; Secrets encrypted at
  rest with `secretbox`; etcd snapshots with k3s's defaults (every 12 hours,
  the last 5, in `/var/lib/rancher/k3s/server/db/snapshots`). Hardened as
  the [K3s CIS hardening guide](https://docs.k3s.io/security/hardening-guide)
  says: `protect-kernel-defaults` with its kernel parameters, Pod Security
  Admission `restricted` outside kube-system and the namespaces subsystems
  exempt (`backfabric.k3s.podSecurityExemptions`, each limited to
  digest-pinned images, ADR 0024), EventRateLimit, every API
  request audited at level Metadata to
  `/var/lib/rancher/k3s/server/logs/audit.log`. Nothing in the cluster is
  reachable from outside: the firewall opens port 6443 only on `cni0`, for
  pods; Services with externalIPs, and of type NodePort or LoadBalancer, are
  rejected. Deviations from the guide:
  [ADR 0017](docs/adr/0017-cluster-hardening-defaults.md). Run `kubectl` on
  the host as root (`ssh <host>`, then `kubectl get nodes`).
  `backfabric.k3s.package` (default `pkgs.k3s_1_36`, the newest minor
  version of the NixOS stable release) pins the k3s minor version: upgrade
  one minor version at a time, with `switch`, never `test` (see the
  template's README).
  `backfabric.k3s.removedManifests` names k3s manifests that are no longer
  deployed (set by modules while they are turned off): each becomes a k3s
  `--disable` entry and its symlink an empty manifest, so k3s deletes the
  objects it applied from it, the file, and its Addon; see the comment in
  [nix/modules/k3s.nix](nix/modules/k3s.nix). Joining more nodes is not
  implemented yet.
- `openbao`: [OpenBao](https://openbao.org/) on the host
  ([ADR 0009](docs/adr/0009-openbao-on-host-with-eso.md)), the upstream
  `services.openbao` with raft storage, no UI. Static seal with
  `openbao-seal-key` and TLS only with a CA and a server certificate for
  `openbao.openbao.svc` and 127.0.0.1, from
  `backfabric.secrets.commonFile` (generated by `backfabric keygen`, which
  keeps the CA key in the admins-only `secrets/admin.yaml`; never change
  the seal key). Listens on 127.0.0.1 and the node address, port
  8200, open only on `cni0`; pods reach it as
  `https://openbao.openbao.svc:8200` through a Service without selector
  ([ADR 0019](docs/adr/0019-openbao-tls-name-and-reviewer.md)). Initialised
  automatically (root token and recovery key in `/var/lib/openbao-init`,
  root only); configured on every deployment: KV v2 at `secret/`, the
  Kubernetes auth method against the local k3s API (clients review their
  own token: their service accounts need `system:auth-delegator`), and the
  options `backfabric.openbao.policies`, `kubernetesRoles`, and
  `kv.secrets` (permanent secrets from sops). Every request audited to
  `/var/log/openbao/audit.log` (values HMACed, rotated daily, 30 kept); a
  raft snapshot daily in `/var/lib/openbao-snapshots` (14 kept). See
  [docs/openbao.md](docs/openbao.md).
- `otel`: an [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
  on the host for audit telemetry
  ([ADR 0021](docs/adr/0021-audit-telemetry-collector-on-host.md)), the
  upstream `services.opentelemetry-collector` with the `otelcol-k8s`
  distribution. OTLP gRPC 4317 and HTTP 4318, TLS only with a certificate
  for `otel-collector.otel.svc` and 127.0.0.1 from OpenBao's CA (generated
  by `backfabric keygen`), on 127.0.0.1 and the node address, open only on
  `cni0`; pods reach it through a Service without selector. Every sender
  authenticates with a projected service account token for the audience
  `otel-collector`; the Collector stamps the verified namespace and service
  account onto the data, replacing what the sender claims, masks
  credentials, and writes everything to an append-only archive of OTLP JSON
  lines in `/var/log/otel-collector` (root only, one file per signal,
  rotated at 100 MB, kept 365 days). See [docs/otel.md](docs/otel.md).
- `substrate` (off unless `backfabric.substrate.enable`):
  [Agent Substrate](https://github.com/agent-substrate/substrate) v1.0.0
  ([ADR 0023](docs/adr/0023-agent-substrate-runtime.md)), installed by its
  own `ate-setup` from the release's images at every deployment that
  changes it, with the beta Kubernetes features its pod certificates need,
  gVisor sandboxes only, its bundled PostgreSQL and a RustFS S3 server for
  snapshots in `ate-system` on static local volumes in `/var/lib/substrate`,
  and `kubectl ate` on the host. `ate-system` and the namespaces of
  `workerPoolNamespaces` are exempt from Pod Security; their pods may only
  run digest-pinned images. See [docs/substrate.md](docs/substrate.md).
- `postgres` (off by default): a PostgreSQL for platform services in the
  cluster, run by [CloudNativePG](https://cloudnative-pg.io/)
  ([ADR 0025](docs/adr/0025-platform-postgres-with-cloudnativepg.md)) from
  its release manifest with images pinned by digest. One Cluster,
  `platform` in `postgres`, one instance on a static local volume in
  `/var/lib/postgres-platform`, TLS, no network superuser, no backups yet.
  `backfabric.postgres.databases` declares each database, its owner and
  the namespace of the service that uses it: only those namespaces may
  connect, and each gets a Secret with the connection details and a
  generated password. See [docs/postgres.md](docs/postgres.md).

## Checks

CI evaluates; the only things it builds are the agent image
([ADR 0022](docs/adr/0022-ci-builds-the-agent-image.md)) and the website
([ADR 0026](docs/adr/0026-project-website-in-the-repository.md)). Run the
same checks locally with:

```sh
nix flake check --no-build --all-systems
nix fmt -- --ci   # formatting check; `nix fmt` formats in place
```
