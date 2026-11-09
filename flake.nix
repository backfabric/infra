{
  description = "NixOS modules for an encrypted k3s cluster on Hetzner bare metal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # Subsystem modules registered in ./modules/default.nix.
      subsystems = import ./modules inputs;

      # Systems of the machines the operator works on.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      exampleSingleNode = lib.nixosSystem {
        modules = [
          self.nixosModules.default
          ./examples/single-node
        ];
      };

      # The example host with one disk instead of two, so that the
      # single-disk layout is evaluated as well.
      exampleSingleDisk = exampleSingleNode.extendModules {
        modules = [
          { backfabric.disks.devices = lib.mkForce [ "/dev/disk/by-id/nvme-EXAMPLE_DISK_0" ]; }
        ];
      };
    in
    {
      nixosModules = subsystems // {
        default = {
          imports = lib.attrValues subsystems;
        };
      };

      lib.mkFleetShell = import ./fleet/shell.nix;

      # The install command on its own, for a host whose public keys do not
      # exist yet (see docs/fleet-shell.md).
      packages = forAllSystems (pkgs: {
        backfabric-install = pkgs.callPackage ./fleet/install.nix { };
      });

      # Evaluated by `nix flake check --no-build`, like the checks.
      devShells = forAllSystems (pkgs: {
        example-fleet = self.lib.mkFleetShell {
          inherit pkgs;
          nixosConfigurations.example = exampleSingleNode;
        };
      });

      # Evaluated by `nix flake check --no-build`; never built in CI.
      checks.x86_64-linux = {
        example-single-node = exampleSingleNode.config.system.build.toplevel;
        example-single-disk = exampleSingleDisk.config.system.build.toplevel;
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
