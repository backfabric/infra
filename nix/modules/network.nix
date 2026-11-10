# Static networking for a Hetzner dedicated server, in the booted system and
# in the systemd initrd (so that the disks can be unlocked over SSH).
#
# One systemd-networkd unit matches the uplink by MAC address, because
# predictable interface names depend on the systemd version. The IPv4 address
# is configured as /32 with the gateway as peer, as Hetzner documents for
# dedicated servers: the main IPv4 comes from a larger subnet, but the server
# may only talk to its gateway.
#
# IPv4 only (docs/adr/0016-ipv4-only-hosts.md): IPv6 is disabled in the
# booted system (`networking.enableIPv6`), and the uplink gets no IPv6
# address, not even link-local, in both stages (the sysctl does not reach
# the initrd).
#
# The NIC kernel module for the initrd comes from nixos-facter
# (`hardware.facter` in nixpkgs): with a report and initrd networking enabled,
# it adds the drivers of the detected network controllers to
# `boot.initrd.kernelModules`.
{ config, lib, ... }:
let
  cfg = config.backfabric.network;

  uplink = {
    matchConfig.MACAddress = cfg.macAddress;
    addresses = [
      {
        Address = "${cfg.ipv4.address}/32";
        Peer = "${cfg.ipv4.gateway}/32";
      }
    ];
    gateway = [ cfg.ipv4.gateway ];
    networkConfig = {
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
    dns = cfg.nameservers;
  };
in
{
  options.backfabric.network = {
    macAddress = lib.mkOption {
      type = lib.types.strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}";
      example = "00:00:5e:00:53:01";
      description = "MAC address of the uplink interface.";
    };

    ipv4 = {
      address = lib.mkOption {
        type = lib.types.str;
        example = "203.0.113.10";
        description = "Main IPv4 address, without prefix length; configured as /32.";
      };
      gateway = lib.mkOption {
        type = lib.types.str;
        example = "203.0.113.1";
        description = "IPv4 gateway, as shown in the Hetzner Robot.";
      };
    };

    nameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # https://docs.hetzner.com/robot/dedicated-server/general-information/recursive-name-servers/
      default = [
        "185.12.64.1"
        "185.12.64.2"
      ];
      description = ''
        Recursive DNS servers. The default are Hetzner's resolvers, which only
        answer servers inside Hetzner's data centers.
      '';
    };
  };

  config = {
    # nixos-facter reports contain no MAC addresses, so `macAddress` cannot
    # be checked here; `backfabric probe` and `backfabric install` check it
    # on the server, and that its driver is in the initrd.
    assertions = [
      {
        assertion =
          config.hardware.facter.enable
          && config.hardware.facter.detected.boot.initrd.networking.kernelModules != [ ];
        message = ''
          backfabric.network: no network driver for the initrd, so the disks
          could not be unlocked over SSH. Set hardware.facter.reportPath to the
          host's nixos-facter report (backfabric probe writes it); its
          hardware.network_controller entries must list driver_modules.
        '';
      }
    ];

    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.enableIPv6 = false;
    systemd.network.networks."10-uplink" = uplink;

    # With a report, facter enables DHCP on every detected interface.
    hardware.facter.detected.dhcp.enable = false;

    boot.initrd.systemd.enable = true;
    # Also makes facter add the NIC drivers to the initrd.
    boot.initrd.network.enable = true;
    boot.initrd.systemd.network.networks."10-uplink" = uplink;
  };
}
