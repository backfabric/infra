{
  description = "Private fleet repository: the hosts and secrets of a backfabric cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    backfabric = {
      url = "github:backfabric/infra";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      backfabric,
    }:
    let
      inherit (nixpkgs) lib;

      # A host: the backfabric modules, the cluster-wide secrets (the k3s
      # token; created by `backfabric keygen`), and the host's directory.
      mkHost =
        path:
        lib.nixosSystem {
          modules = [
            backfabric.nixosModules.default
            { backfabric.secrets.commonFile = ./secrets/common.yaml; }
            path
          ];
        };

      # Systems of the machines you operate the fleet from.
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Every host, listed explicitly. The attribute name is the host's SSH
      # alias in the dev shell and the argument of the backfabric commands.
      nixosConfigurations = {
        # node1 = mkHost ./hosts/node1;
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          inputsFrom = [
            (backfabric.lib.mkFleetShell {
              inherit pkgs;
              inherit (self) nixosConfigurations;
            })
          ];
          # Where sops finds your admin key; location and kind are your choice.
          # shellHook = ''
          #   export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/fleet.txt
          # '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
