# Example single-node host. Contains no real host data; it exists so that
# `nix flake check` evaluates the modules in a complete NixOS configuration.
# Addresses are from the documentation ranges (RFC 5737, RFC 3849, RFC 7042).
{
  networking.hostName = "example";

  # Fake disk ids, matching the report below; a real host takes them from
  # the hardware summary of `backfabric probe`.
  backfabric.disks.devices = [
    "/dev/disk/by-id/nvme-EXAMPLE_DISK_0"
    "/dev/disk/by-id/nvme-EXAMPLE_DISK_1"
  ];

  backfabric.network = {
    macAddress = "00:00:5e:00:53:01";
    ipv4 = {
      address = "203.0.113.10";
      gateway = "203.0.113.1";
    };
  };

  backfabric.access = {
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE example"
    ];
    ssh.port = 2222;
    initrdSsh.port = 2223;
    # Throwaway keys whose private parts were discarded. A real host reads the
    # files that `backfabric keygen` writes next to its configuration.
    hostKey.publicKey = builtins.readFile ./ssh_host_ed25519_key.pub;
    initrdSsh.publicKey = builtins.readFile ./initrd_ssh_host_ed25519_key.pub;
  };

  # A real host reads the cluster-wide secrets (the k3s token, OpenBao's
  # seal key and TLS material, the OpenTelemetry Collector's TLS material)
  # from `secrets/common.yaml` of the private
  # repository (set once for every host, in the template's `mkHost`), and its
  # own from `secrets/<host>.yaml`, files encrypted for the host. The example
  # has no encrypted files, so the paths do not exist and sops-nix must not
  # check them at evaluation time.
  backfabric.secrets.commonFile = "/example/secrets/common.yaml";
  sops.defaultSopsFile = "/example/secrets/example.yaml";
  sops.validateSopsFiles = false;

  # What External Secrets Operator will need: a policy, a Kubernetes auth
  # role for its service account, and a permanent secret loaded from sops
  # (`example-app-password` in the host's sops file).
  backfabric.openbao = {
    policies.external-secrets = ''
      path "secret/data/*" {
        capabilities = ["read"]
      }
    '';
    kubernetesRoles.external-secrets = {
      serviceAccounts = [ "external-secrets" ];
      namespaces = [ "external-secrets" ];
      policies = [ "external-secrets" ];
    };
    kv.secrets."example/app".password = "example-app-password";
  };

  # A real host sets `hardware.facter.reportPath = ./facter.json;` instead,
  # with the report that `backfabric probe` generates with nixos-facter. This
  # excerpt has the shape of a real report of a Hetzner server (fields the
  # modules and `backfabric probe` read): the platform (which, as on a real
  # host, sets nixpkgs.hostPlatform), a network controller with its driver
  # (for the initrd), and the disks with their by-id names, which the
  # `disks` module checks `backfabric.disks.devices` against. Reports contain
  # no MAC addresses.
  hardware.facter.report =
    let
      disk = index: serial: {
        model = "EXAMPLE NVMe 1TB";
        driver_modules = [ "nvme" ];
        unix_device_names = [
          "/dev/disk/by-id/nvme-EXAMPLE_DISK_${toString index}"
          "/dev/disk/by-id/nvme-eui.000000000000000${serial}"
          "/dev/disk/by-path/pci-0000:0${toString (index + 1)}:00.0-nvme-1"
          "/dev/nvme${toString index}n1"
        ];
        resources = [
          {
            type = "size";
            unit = "sectors";
            value_1 = 2000409264;
            value_2 = 512;
          }
        ];
      };
    in
    {
      version = 1;
      system = "x86_64-linux";
      virtualisation = "none";
      uefi = {
        supported = false;
      };
      hardware = {
        cpu = [
          {
            vendor_name = "AuthenticAMD";
            model_name = "AMD Ryzen 9 3900 12-Core Processor";
            cores = 12;
            units = 24;
          }
        ];
        memory = [
          {
            model = "Main Memory";
            resources = [
              {
                type = "phys_mem";
                range = 137438953472;
              }
            ];
          }
        ];
        network_controller = [
          {
            model = "Intel Ethernet controller";
            driver_modules = [ "igb" ];
            unix_device_names = [ "enp35s0" ];
            resources = [
              {
                type = "hwaddr";
                address = 48;
              }
            ];
          }
        ];
        disk = [
          (disk 0 "a")
          (disk 1 "b")
        ];
      };
    };

  system.stateVersion = "26.05";
}
