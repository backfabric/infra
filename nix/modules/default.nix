# Registry of subsystem modules.
#
# Each subsystem lives in its own file, `nix/modules/<subsystem>.nix`, declares its
# options under `backfabric.<subsystem>`, and is registered here. The flake
# exports every entry as `nixosModules.<subsystem>`, and
# `nixosModules.default` imports all of them.
#
# The registry is a function of the flake inputs so that an entry can import
# the NixOS modules its subsystem depends on; consumers then only import
# modules from this flake.
inputs: {
  disks = {
    imports = [
      inputs.disko.nixosModules.disko
      ./disks.nix
    ];
  };
  network = ./network.nix;
  access = ./access.nix;
  secrets = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ./secrets.nix
    ];
  };
  # Also imports the subsystems it reads options of (the node address, the
  # cluster-wide sops file); the same paths in other entries are imported
  # once.
  k3s = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ./secrets.nix
      ./network.nix
      ./k3s.nix
    ];
  };
  # Also imports the subsystems it reads options of or configures (the node
  # address, the cluster-wide sops file, k3s's manifests and server CA).
  openbao = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ./secrets.nix
      ./network.nix
      ./k3s.nix
      ./openbao.nix
    ];
  };
}
