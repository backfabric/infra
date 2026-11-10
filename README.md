# backfabric/infra

NixOS modules for running an encrypted k3s cluster on Hetzner bare metal,
intended as the substrate for running agents.

This flake is public and contains no host-specific data. Concrete hosts, IP
addresses, and secrets live in a separate private repository that consumes
these modules.

Status: work in progress.

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
- `docs/`: operational runbooks:
  [the fleet dev shell and installing a host](docs/fleet-shell.md),
  [replacing a failed disk](docs/disk-replacement.md),
  [unlocking the disks over SSH](docs/initrd-unlock.md),
  [managing secrets](docs/secrets.md);
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
  systemd-networkd, in the booted system and in the initrd; the uplink is
  renamed `uplink` (a .link unit matched by the MAC, effective from the next
  boot); IPv6 is
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
  the only port open from outside in the (nftables) firewall, and only on
  the interface `uplink` (pods cannot reach it); no ping replies. The initrd
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
  the last 5, in `/var/lib/rancher/k3s/server/db/snapshots`). Nothing in
  the cluster is reachable from outside: the firewall opens port 6443 only
  on `cni0`, for pods; NodePorts answer only on 127.0.0.0/8; Services with
  externalIPs are rejected; Pod Security Admission enforces `baseline`
  (audit and warn `restricted`) outside kube-system. Every API request is
  audited at level Metadata to `/var/log/kubernetes/audit.log`. See
  [ADR 0017](docs/adr/0017-cluster-hardening-defaults.md). Run `kubectl` on
  the host as root (`ssh <host>`, then `kubectl get nodes`).
  `backfabric.k3s.package` (default `pkgs.k3s_1_35`) pins the k3s minor
  version: upgrade one minor version at a time. Joining more nodes is not
  implemented yet.

## Checks

CI only evaluates; nothing is built. Run the same checks locally with:

```sh
nix flake check --no-build --all-systems
nix fmt -- --ci   # formatting check; `nix fmt` formats in place
```
