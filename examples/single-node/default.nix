# Example single-node host. Contains no real host data; it exists so that
# `nix flake check` evaluates the modules in a complete NixOS configuration.
# Addresses are from the documentation ranges (RFC 5737, RFC 3849, RFC 7042).
{
  networking.hostName = "example";

  # Fake disk ids; a real host takes them from `ls -l /dev/disk/by-id`.
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
    ipv6.address = "2001:db8::2/64";
  };

  backfabric.access = {
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE example"
    ];
    ssh.port = 2222;
    initrdSsh.port = 2223;
    # Throwaway keys whose private parts were discarded. A real host reads the
    # files that the install command writes next to its configuration.
    hostKey.publicKey = builtins.readFile ./ssh_host_ed25519_key.pub;
    initrdSsh.publicKey = builtins.readFile ./initrd_ssh_host_ed25519_key.pub;
  };

  # A real host sets `hardware.facter.reportPath = ./facter.json;` instead,
  # with the report generated on the server by nixos-facter. This stub only
  # names the platform (which, as on a real host, sets nixpkgs.hostPlatform)
  # and a network driver, so that the initrd networking path is evaluated.
  hardware.facter.report = {
    system = "x86_64-linux";
    hardware.network_controller = [ { driver_modules = [ "igb" ]; } ];
  };

  system.stateVersion = "26.05";
}
