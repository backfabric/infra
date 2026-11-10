# Disk layout and boot loader for the system disks.
#
# Every disk in `backfabric.disks.devices` gets the same GPT layout:
#
#   - BIOS boot partition (EF02), so GRUB can boot in legacy BIOS mode;
#   - ESP (vfat), mounted at /boot for the first disk and /boot-<n> for the
#     others; GRUB is installed to every disk and mirrored to every ESP;
#   - LUKS partition for the rest of the disk, opened as /dev/mapper/crypt<n>.
#
# One btrfs file system spans all LUKS devices: raid1 for data and metadata
# with two or more disks, mkfs.btrfs defaults with a single disk.
{ config, lib, ... }:
let
  cfg = config.backfabric.disks;

  # Index-keyed attribute sets; `disk<n>` is the disko disk name.
  disks = lib.imap0 (index: device: {
    name = "disk${toString index}";
    inherit device;
    luksName = "crypt${toString index}";
    espMountpoint = if index == 0 then "/boot" else "/boot-${toString index}";
  }) cfg.devices;

  # disko formats disks in alphabetical order of their names and btrfs needs
  # every member when it is created, so the last disk in that order carries
  # the file system and lists the other LUKS devices as extra members.
  carrier = lib.last (lib.sort (a: b: a.name < b.name) disks);
  members = lib.filter (disk: disk.name != carrier.name) disks;

  btrfs = {
    type = "btrfs";
    extraArgs = lib.optionals (members != [ ]) (
      [
        "-d"
        "raid1"
        "-m"
        "raid1"
      ]
      ++ map (disk: "/dev/mapper/${disk.luksName}") members
    );
    subvolumes =
      let
        mountOptions = [
          "compress=zstd"
          "noatime"
        ];
      in
      {
        "@" = {
          mountpoint = "/";
          inherit mountOptions;
        };
        "@nix" = {
          mountpoint = "/nix";
          inherit mountOptions;
        };
      };
  };

  diskoDisk = disk: {
    type = "disk";
    inherit (disk) device;
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
        };
        esp = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = disk.espMountpoint;
            mountOptions = [ "umask=0077" ];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = disk.luksName;
            # Read only when formatting. nixos-anywhere copies the passphrase
            # here with `--disk-encryption-keys /tmp/disk-encryption.key <file>`.
            passwordFile = "/tmp/disk-encryption.key";
            # TRIM for SSDs; reveals which blocks are unused.
            settings.allowDiscards = true;
          }
          // lib.optionalAttrs (disk.name == carrier.name) { content = btrfs; };
        };
      };
    };
  };
in
{
  options.backfabric.disks = {
    devices = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.strMatching "/dev/disk/by-id/.+");
      example = [
        "/dev/disk/by-id/nvme-SAMSUNG_MZVL2512HCJQ-00B00_S000000000000A"
        "/dev/disk/by-id/nvme-SAMSUNG_MZVL2512HCJQ-00B00_S000000000000B"
      ];
      description = ''
        System disks, by stable id. All of them are partitioned, encrypted with
        the same passphrase, and joined into one btrfs file system (raid1 with
        two or more disks). GRUB is installed to every disk.
      '';
    };
  };

  config = {
    # The report lists every name of a disk, including its /dev/disk/by-id/
    # links, in `hardware.disk[].unix_device_names`.
    assertions =
      let
        reported = lib.concatMap (disk: disk.unix_device_names or [ ]) (
          config.hardware.facter.report.hardware.disk or [ ]
        );
      in
      lib.optionals config.hardware.facter.enable (
        map (device: {
          assertion = lib.elem device reported;
          message = ''
            backfabric.disks.devices: ${device} is not a disk in the
            nixos-facter report (hardware.facter.reportPath). Use the
            /dev/disk/by-id/ names that backfabric probe lists for the disks.
          '';
        }) cfg.devices
      );

    disko.devices.disk = lib.listToAttrs (
      map (disk: lib.nameValuePair disk.name (diskoDisk disk)) disks
    );

    boot.loader.grub = {
      enable = true;
      efiSupport = true;
      # Install to the fallback path EFI/BOOT/BOOTX64.EFI on every ESP instead
      # of relying on NVRAM boot entries.
      efiInstallAsRemovable = true;
      # disko adds every disk with an EF02 partition to `devices`, which would
      # add a second /boot entry to `mirroredBoots` covering all disks.
      devices = lib.mkForce [ ];
      mirroredBoots = map (disk: {
        path = disk.espMountpoint;
        devices = [ disk.device ];
      }) disks;
    };
  };
}
