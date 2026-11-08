{
  description = "NixOS modules for an encrypted k3s cluster on Hetzner bare metal";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # Subsystem modules registered in ./modules/default.nix.
      subsystems = import ./modules;

      formatterSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      exampleSingleNode = lib.nixosSystem {
        modules = [
          self.nixosModules.default
          ./examples/single-node
        ];
      };
    in
    {
      nixosModules = subsystems // {
        default = {
          imports = lib.attrValues subsystems;
        };
      };

      # Evaluated by `nix flake check --no-build`; never built in CI.
      checks.x86_64-linux.example-single-node = exampleSingleNode.config.system.build.toplevel;

      formatter = lib.genAttrs formatterSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
