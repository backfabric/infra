# backfabric/infra

NixOS modules for running an encrypted k3s cluster on Hetzner bare metal,
intended as the substrate for running agents.

This flake is public and contains no host-specific data. Concrete hosts, IP
addresses, and secrets live in a separate private repository that consumes
these modules.

Status: work in progress.

## Layout

- `modules/<subsystem>.nix`: one NixOS module per subsystem, with options
  under `backfabric.<subsystem>`. Each subsystem is registered in
  `modules/default.nix` and exported as `nixosModules.<subsystem>`. The
  registry is a function of the flake inputs, so an entry also imports the
  NixOS modules of the inputs its subsystem needs (e.g. disko for `disks`);
  consumers only import modules from this flake.
- `nixosModules.default` imports every subsystem module.
- `fleet/`: the fleet dev shell for the operator machine,
  `lib.mkFleetShell { pkgs, nixosConfigurations }`, with a generated SSH
  config, the install command `backfabric-install`, and the `.sops.yaml`
  commands `backfabric-sops-init` and `backfabric-sops-add-host` (each also
  `packages.<system>.<command>`), see [docs/fleet-shell.md](docs/fleet-shell.md)
  and [docs/secrets.md](docs/secrets.md).
- `examples/single-node/`: an example host with two disks, evaluated by
  `checks.x86_64-linux.example-single-node`, and with one disk by
  `checks.x86_64-linux.example-single-disk`; its fleet dev shell is
  `devShells.<system>.example-fleet`.
- `templates/default/`: the skeleton of the private repository, see below;
  evaluated by `checks.x86_64-linux.template-empty` and
  `checks.x86_64-linux.template-with-host`.
- `docs/`: operational runbooks:
  [the fleet dev shell and installing a host](docs/fleet-shell.md),
  [replacing a failed disk](docs/disk-replacement.md),
  [unlocking the disks over SSH](docs/initrd-unlock.md),
  [managing secrets](docs/secrets.md).

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
  system disks. The install command passes the LUKS passphrase to
  nixos-anywhere with `--disk-encryption-keys /tmp/disk-encryption.key <file>`.
- `network`: static IPv4 and IPv6 on the uplink, matched by MAC address,
  with systemd-networkd, in the booted system and in the initrd. Set
  `backfabric.network.macAddress`, `ipv4.address`, `ipv4.gateway`, and
  `ipv6.address` (with `/64`) from the Hetzner Robot; `ipv6.gateway`
  (`fe80::1`) and `nameservers` (Hetzner's resolvers) have defaults. The
  initrd network driver comes from nixos-facter: set
  `hardware.facter.reportPath` to the host's report (e.g. `./facter.json`),
  which the install command generates if it is missing. Evaluation fails
  without it.
- `access`: root login with SSH keys only on `backfabric.access.ssh.port`,
  the only port open in the (nftables) firewall; no ping replies. The initrd
  runs an SSH server on `backfabric.access.initrdSsh.port` to unlock the
  disks, see [docs/initrd-unlock.md](docs/initrd-unlock.md). Set
  `authorizedKeys`, both ports, and the public host keys
  `hostKey.publicKey` and `initrdSsh.publicKey` from the `.pub` files the
  install command writes next to the facter report.
- `secrets`: sops-nix, decrypting with the SSH ed25519 host key
  (`/etc/ssh/ssh_host_ed25519_key`) only; no options of its own. Set
  `sops.defaultSopsFile` to the encrypted file; other subsystems declare
  their own `sops.secrets.*`. The install command copies the host key with
  nixos-anywhere `--extra-files` so the first boot can decrypt, see
  [docs/secrets.md](docs/secrets.md).

## Checks

CI only evaluates; nothing is built. Run the same checks locally with:

```sh
nix flake check --no-build --all-systems
nix fmt -- --ci   # formatting check; `nix fmt` formats in place
```
