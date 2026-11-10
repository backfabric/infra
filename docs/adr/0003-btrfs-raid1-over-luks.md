# btrfs raid1 over per-disk LUKS, GRUB on every disk, manual degraded recovery

Every system disk gets a BIOS boot partition, an ESP, and a LUKS partition; one btrfs file system spans all LUKS devices (raid1 for data and metadata with two or more disks), and GRUB is installed to every disk and mirrored to every ESP, so the server boots from either disk in BIOS and UEFI mode. A missing disk is recovered by hand from the Hetzner Rescue system (`docs/disk-replacement.md`); the system does not mount degraded on its own, because writes on a degraded raid1 are unmirrored and need a balance after the replacement. RAID here protects data; availability comes from more nodes.

## Considered Options

- mdadm RAID1 + LUKS + ext4: more conservative, rejected in favour of btrfs, which the user runs everywhere.
- ZFS mirror with native encryption: needs a separate containerd snapshotter and an out-of-tree kernel module.
