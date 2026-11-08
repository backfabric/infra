# Example single-node host. Contains no real host data; it exists so that
# `nix flake check` evaluates the modules in a complete NixOS configuration.
{
  nixpkgs.hostPlatform = "x86_64-linux";

  # Temporary values so the configuration evaluates.
  # Stage 2 (disks and boot) replaces them with the backfabric disk layout.
  boot.loader.grub.devices = [ "nodev" ];
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  system.stateVersion = "26.05";
}
