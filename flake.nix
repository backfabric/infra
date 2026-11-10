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

      # The example host before its first install: the report at
      # `reportPath` does not exist yet, so neither does its platform.
      exampleWithoutReport = exampleSingleNode.extendModules {
        modules = [
          {
            hardware.facter = {
              reportPath = ./examples/single-node/facter.json;
              # What the upstream default of `report` does with `reportPath`.
              report = lib.mkForce (lib.importJSON ./examples/single-node/facter.json);
            };
          }
        ];
      };

      # The facts the backfabric command reads (fleet/facts.nix), as an
      # evaluation-only check.
      fleetFacts =
        name: system: reportPathOk:
        let
          facts = import ./fleet/facts.nix system;
        in
        assert facts.address == "203.0.113.10";
        assert facts.initrdHostKey == "/etc/secrets/initrd/ssh_host_ed25519_key";
        assert facts.hostPublicKey == builtins.readFile ./examples/single-node/ssh_host_ed25519_key.pub;
        assert reportPathOk facts.reportPath;
        nixpkgs.legacyPackages.x86_64-linux.writeText name (
          builtins.toJSON (removeAttrs facts [ "reportPath" ])
        );

      # The dev shell of every system the template declares, evaluated with
      # this repository as `backfabric` and the given hosts in place of the
      # template's (empty) `nixosConfigurations`.
      templateCheck =
        name: hosts:
        let
          template = import ./templates/default/flake.nix;
          outputs = template.outputs {
            self = outputs // {
              nixosConfigurations = hosts;
            };
            inherit nixpkgs;
            backfabric = self;
          };
        in
        assert outputs.nixosConfigurations == { };
        nixpkgs.legacyPackages.x86_64-linux.writeText name (
          builtins.unsafeDiscardStringContext (
            builtins.toJSON (lib.mapAttrs (_: shells: shells.default.drvPath) outputs.devShells)
          )
        );
    in
    {
      nixosModules = subsystems // {
        default = {
          imports = lib.attrValues subsystems;
        };
      };

      lib.mkFleetShell = import ./fleet/shell.nix;

      # The operator command `backfabric` on its own, for a host whose public
      # keys do not exist yet (see docs/fleet-shell.md).
      packages = forAllSystems (
        pkgs:
        let
          backfabric = pkgs.callPackage ./fleet/cli { };
        in
        {
          inherit backfabric;
          default = backfabric;
        }
      );

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
        fleet-facts-with-report = fleetFacts "fleet-facts-with-report" exampleSingleNode (
          reportPath: reportPath == null
        );
        fleet-facts-without-report = fleetFacts "fleet-facts-without-report" exampleWithoutReport (
          lib.hasSuffix "/examples/single-node/facter.json"
        );
        # The template right after `nix flake init`, and with the example host
        # (built as the template's `mkHost` builds a host; its toplevel is
        # `example-single-node`).
        template-empty = templateCheck "template-empty" { };
        template-with-host = templateCheck "template-with-host" { node1 = exampleSingleNode; };
      };

      templates.default = {
        path = ./templates/default;
        description = "Private fleet repository: hosts and secrets using these modules";
        welcomeText = ''
          # Private fleet repository

          Next: `git init && git add -A && git commit`, then follow README.md
          (sops init, add a host, install).
        '';
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
