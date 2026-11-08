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
- `examples/single-node/`: an example host with two disks, evaluated by
  `checks.x86_64-linux.example-single-node`, and with one disk by
  `checks.x86_64-linux.example-single-disk`.
- `docs/`: operational runbooks, e.g.
  [replacing a failed disk](docs/disk-replacement.md).

## Subsystems

- `disks`: per system disk a BIOS boot partition, an ESP, and a LUKS
  partition; one btrfs file system across all disks, raid1 with two or more
  (subvolumes `@` for `/`, `@nix` for `/nix`); GRUB mirrored to every disk
  for BIOS and UEFI boot. Set
  `backfabric.disks.devices` to the `/dev/disk/by-id/...` paths of the
  system disks. When installing with nixos-anywhere, pass the LUKS passphrase
  with `--disk-encryption-keys /tmp/disk-encryption.key <file>`.

## Checks

CI only evaluates; nothing is built. Run the same checks locally with:

```sh
nix flake check --no-build --all-systems
nix fmt -- --ci   # formatting check; `nix fmt` formats in place
```
