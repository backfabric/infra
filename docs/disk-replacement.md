# Replacing a failed system disk

Runbook for a host using the `disks` module with two or more disks on Hetzner
bare metal. A single-disk host has no redundancy: reinstall it instead.

## Background

- Disk `<n>` is entry `<n>` (counting from 0) of `backfabric.disks.devices`.
  Its partitions are labeled `disk-disk<n>-bios`, `disk-disk<n>-esp`, and
  `disk-disk<n>-luks`; the LUKS device is opened as `crypt<n>`; its ESP is
  mounted at `/boot` (disk 0) or `/boot-<n>`.
- The btrfs file system is raid1 across all `crypt<n>` devices. It is never
  mounted `degraded` automatically, so a host with a missing disk does not
  boot. Repairs happen from the Hetzner Rescue system.

## 1. Identify the failed disk

On the running host (if it still runs), or later in the Rescue system:

```sh
btrfs device stats /
btrfs filesystem show /
ls -l /dev/disk/by-id/
```

Note the failed disk's position `<n>` in `backfabric.disks.devices` and its
serial number, then ask Hetzner support to replace that disk.

## 2. Boot the Rescue system

In Hetzner Robot: Server > Rescue > Linux 64 bit with your SSH key, activate,
then Reset > hardware reset. Log in with `ssh root@<host>`. If a tool used
below is missing, install it with `apt install`.

```sh
lsblk -o NAME,SIZE,SERIAL,PARTLABEL
ls -l /dev/disk/by-id/
N=<n>                              # position of the replaced disk
NEW=/dev/disk/by-id/<new-disk-id>  # the new, empty disk
```

## 3. Unlock the remaining disks and mount degraded

For every surviving disk `<i>` (same passphrase for all):

```sh
cryptsetup open /dev/disk/by-partlabel/disk-disk<i>-luks crypt<i>
```

Then mount the top level of the file system:

```sh
btrfs device scan
mkdir -p /mnt/btrfs
mount -o degraded /dev/mapper/crypt<i> /mnt/btrfs
btrfs filesystem show /mnt/btrfs   # note the devid of the missing device
```

## 4. Partition the new disk

Recreate the layout of the `disks` module, with the labels of position `<n>`:

```sh
sgdisk --zap-all "$NEW"
sgdisk \
  --new=1:0:+1M --typecode=1:EF02 --change-name=1:disk-disk$N-bios \
  --new=2:0:+1G --typecode=2:EF00 --change-name=2:disk-disk$N-esp \
  --new=3:0:0 --typecode=3:8300 --change-name=3:disk-disk$N-luks \
  "$NEW"
partprobe "$NEW"; udevadm settle

mkfs.vfat /dev/disk/by-partlabel/disk-disk$N-esp
cryptsetup luksFormat /dev/disk/by-partlabel/disk-disk$N-luks  # same passphrase as the other disks
cryptsetup open --allow-discards --persistent \
  /dev/disk/by-partlabel/disk-disk$N-luks crypt$N
```

## 5. Rebuild the mirror

```sh
btrfs replace start -B <missing-devid> /dev/mapper/crypt$N /mnt/btrfs
# Chunks written while mounted degraded may use the single profile:
btrfs balance start -dconvert=raid1,soft -mconvert=raid1,soft /mnt/btrfs
btrfs filesystem usage /mnt/btrfs  # Data, Metadata, and System must be RAID1 only
umount /mnt/btrfs
```

## 6. Update the configuration

In the private repository, replace the failed entry of
`backfabric.disks.devices` with the new disk id, at the same position. Commit
and push.

## 7. Reinstall GRUB

Mount the installed system, using the host's own NixOS tools through a bind
mount of its `/nix`:

```sh
mount -o subvol=@ /dev/mapper/crypt<i> /mnt
mount -o subvol=@nix /dev/mapper/crypt<i> /mnt/nix
mount /dev/disk/by-partlabel/disk-disk0-esp /mnt/boot
mount /dev/disk/by-partlabel/disk-disk1-esp /mnt/boot-1  # and so on for every disk
mkdir -p /nix && mount --bind /mnt/nix /nix
/mnt/nix/var/nix/profiles/system/sw/bin/nixos-enter --root /mnt
```

Inside `nixos-enter`, build the updated configuration (this needs read access
to the private repository) and install the boot loader to every disk:

```sh
nix --extra-experimental-features 'nix-command flakes' build \
  --profile /nix/var/nix/profiles/system \
  '<private-repo-flake>#nixosConfigurations.<host>.config.system.build.toplevel'
NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot
exit
```

## 8. Reboot and verify

```sh
umount -R /mnt; umount /nix
reboot
```

The Rescue system is active for one boot only; the host now boots from its
disks. After unlocking:

```sh
btrfs filesystem show /
btrfs filesystem usage /   # RAID1 only
btrfs device stats -z /    # print and reset the error counters
```
