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

      # Subsystem modules registered in ./nix/modules/default.nix.
      subsystems = import ./nix/modules inputs;

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
          ./nix/examples/single-node
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
              reportPath = ./nix/examples/single-node/facter.json;
              # What the upstream default of `report` does with `reportPath`.
              report = lib.mkForce (lib.importJSON ./nix/examples/single-node/facter.json);
            };
          }
        ];
      };

      # Variants of the example whose facter report does not match its
      # configuration.
      exampleWithReport =
        change:
        exampleSingleNode.extendModules {
          modules = [
            {
              hardware.facter.report = lib.mkForce (
                lib.recursiveUpdate exampleSingleNode.config.hardware.facter.report change
              );
            }
          ];
        };
      exampleWithoutNicDriver = exampleWithReport {
        hardware.network_controller = [ { driver_modules = [ ]; } ];
      };
      exampleWithMissingDisk = exampleWithReport {
        hardware.disk = lib.take 1 exampleSingleNode.config.hardware.facter.report.hardware.disk;
      };

      # Evaluates the messages of the failed assertions of `system`, without
      # building it: none if `expected` is empty, else for each string in
      # `expected` a message that contains it.
      assertionsCheck =
        name: system: expected:
        let
          failed = map (a: a.message) (lib.filter (a: !a.assertion) system.config.assertions);
          ok =
            if expected == [ ] then
              failed == [ ]
            else
              lib.all (text: lib.any (lib.hasInfix text) failed) expected;
        in
        assert lib.assertMsg ok "${name}: failed assertions: ${builtins.toJSON failed}";
        nixpkgs.legacyPackages.x86_64-linux.writeText name (builtins.toJSON failed);

      # The facts the backfabric command reads (nix/fleet/facts.nix), as an
      # evaluation-only check.
      fleetFacts =
        name: system: reportPathOk:
        let
          facts = import ./nix/fleet/facts.nix system;
        in
        assert facts.address == "203.0.113.10";
        assert facts.initrdHostKey == "/etc/secrets/initrd/ssh_host_ed25519_key";
        assert facts.hostPublicKey == builtins.readFile ./nix/examples/single-node/ssh_host_ed25519_key.pub;
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
          template = import ./nix/templates/default/flake.nix;
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

      lib.mkFleetShell = import ./nix/fleet/shell.nix;

      # The operator command `backfabric` on its own, for a host whose public
      # keys do not exist yet (see docs/fleet-shell.md); the agents' and the
      # dispatcher's container images, built and published by CI only
      # (docs/agent-image.md, dispatcher/README.md), and the dispatcher
      # itself, which builds and runs its tests on every system; and the
      # project website, published by CI to GitHub Pages (ADR 0026).
      packages = forAllSystems (
        pkgs:
        let
          backfabric = pkgs.callPackage ./nix/fleet/cli { };
          dispatcher = pkgs.callPackage ./nix/packages/dispatcher.nix { };
        in
        {
          inherit backfabric dispatcher;
          default = backfabric;
          website = pkgs.callPackage ./nix/website.nix { };
        }
        // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          agent-image = pkgs.callPackage ./nix/images/agent.nix { };
          dispatcher-image = pkgs.callPackage ./nix/images/dispatcher.nix { inherit dispatcher; };
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
        # The assertions that check the configuration against the facter
        # report: all pass for the example, and each mismatch is reported.
        assertions-example = assertionsCheck "assertions-example" exampleSingleNode [ ];
        assertions-single-disk = assertionsCheck "assertions-single-disk" exampleSingleDisk [ ];
        assertions-no-nic-driver = assertionsCheck "assertions-no-nic-driver" exampleWithoutNicDriver [
          "backfabric.network: no network driver for the initrd"
        ];
        assertions-missing-disk = assertionsCheck "assertions-missing-disk" exampleWithMissingDisk [
          "backfabric.disks.devices: /dev/disk/by-id/nvme-EXAMPLE_DISK_1 is not a disk"
        ];
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
        path = ./nix/templates/default;
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
