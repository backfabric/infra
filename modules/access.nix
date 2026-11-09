# SSH access and inbound firewall.
#
#   - sshd: root login with SSH keys only, on `ssh.port`;
#   - initrd: sshd on `initrdSsh.port` with the same keys and a separate host
#     key, to unlock the LUKS disks after a reboot (see docs/initrd-unlock.md);
#   - firewall (nftables backend): inbound closed except `ssh.port`, no ping
#     replies. The initrd has no firewall.
#
# The public host keys are options so that the fleet dev shell (fleet/) can
# generate a known_hosts file for every host.
{ config, lib, ... }:
let
  cfg = config.backfabric.access;

  # One ed25519 public key in OpenSSH format, as in a `.pub` file (the
  # trailing newline of `builtins.readFile` is allowed). Rejects a private
  # key passed by mistake, which would end up in the Nix store.
  publicKeyType = lib.types.strMatching "ssh-ed25519 [A-Za-z0-9+/]+=*( [^\n]*)?\n?";
in
{
  options.backfabric.access = {
    authorizedKeys = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      example = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... admin@example" ];
      description = "SSH public keys allowed to log in as root and to unlock the disks in the initrd.";
    };

    ssh.port = lib.mkOption {
      type = lib.types.port;
      example = 2222;
      description = "Port of the SSH daemon of the booted system; the only port open in the firewall.";
    };

    hostKey.publicKey = lib.mkOption {
      type = publicKeyType;
      example = lib.literalExpression "builtins.readFile ./ssh_host_ed25519_key.pub";
      description = ''
        Public part of the SSH ed25519 host key of the booted system
        (`/etc/ssh/ssh_host_ed25519_key`), written next to the host's
        configuration by the install command.
      '';
    };

    initrdSsh = {
      port = lib.mkOption {
        type = lib.types.port;
        example = 2223;
        description = "Port of the SSH daemon in the initrd, used to unlock the disks.";
      };

      # A string, not a path: a Nix path would be copied into the world-readable
      # Nix store. The key is read from the host when the boot loader is
      # installed and appended to the initrd as an initrd secret.
      hostKey = lib.mkOption {
        type = lib.types.str;
        default = "/etc/secrets/initrd/ssh_host_ed25519_key";
        description = ''
          Path on the host to the private SSH host key of the initrd. It is
          generated at install time and copied with nixos-anywhere
          `--extra-files`. It is not a sops secret: it sits unencrypted in the
          initrd on the ESP, so it must not be the host key of the booted
          system.
        '';
      };

      publicKey = lib.mkOption {
        type = publicKeyType;
        example = lib.literalExpression "builtins.readFile ./initrd_ssh_host_ed25519_key.pub";
        description = ''
          Public part of the initrd host key at `hostKey`, written next to
          the host's configuration by the install command.
        '';
      };
    };
  };

  config = {
    users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys;

    services.openssh = {
      enable = true;
      ports = [ cfg.ssh.port ];
      # Opens `ssh.port` in the firewall; port knocking (Stage 4) replaces this
      # with a rule that opens it only for the knocking source address.
      openFirewall = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    boot.initrd.network.ssh = {
      enable = true;
      inherit (cfg.initrdSsh) port;
      authorizedKeys = cfg.authorizedKeys;
      hostKeys = [ cfg.initrdSsh.hostKey ];
    };

    networking.nftables = {
      enable = true;
      # NixOS only deletes and recreates its own tables on reload. k3s adds
      # its own tables (iptables-nft, kube-router); flushing the whole ruleset
      # would drop them. The upstream default depends on stateVersion and on
      # whether `networking.nftables.ruleset` is set, so pin it.
      flushRuleset = false;
    };

    networking.firewall = {
      enable = true;
      allowPing = false;
    };
  };
}
