# Registry of subsystem modules.
#
# Each subsystem lives in its own file, `modules/<subsystem>.nix`, declares its
# options under `backfabric.<subsystem>`, and is registered here as
# `<subsystem> = ./<subsystem>.nix;`. The flake exports every entry as
# `nixosModules.<subsystem>`, and `nixosModules.default` imports all of them.
{ }
