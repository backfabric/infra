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
  `modules/default.nix` and exported as `nixosModules.<subsystem>`.
- `nixosModules.default` imports every subsystem module.
- `examples/single-node/`: an example host evaluated by
  `checks.x86_64-linux.example-single-node`.

## Checks

CI only evaluates; nothing is built. Run the same checks locally with:

```sh
nix flake check --no-build --all-systems
nix fmt -- --ci   # formatting check; `nix fmt` formats in place
```
