# Example single-node host. Contains no real host data; it exists so that
# `nix flake check` evaluates the modules in a complete NixOS configuration.
{
  nixpkgs.hostPlatform = "x86_64-linux";

  # Fake disk ids; a real host takes them from `ls -l /dev/disk/by-id`.
  backfabric.disks.devices = [
    "/dev/disk/by-id/nvme-EXAMPLE_DISK_0"
    "/dev/disk/by-id/nvme-EXAMPLE_DISK_1"
  ];

  system.stateVersion = "26.05";
}
