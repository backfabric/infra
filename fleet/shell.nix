# Fleet dev shell for the operator machine (`lib.mkFleetShell`), see
# docs/fleet-shell.md.
#
# `pkgs`: package set of the operator machine (e.g. aarch64-darwin).
# `nixosConfigurations`: the hosts; every entry must import this flake's
# `access` and `network` subsystems. The attribute name is the SSH alias.
{ pkgs, nixosConfigurations }:
let
  inherit (pkgs) lib;

  # SSH options per alias. Port knocking (Stage 4) adds a `ProxyCommand` to
  # the alias of the booted system.
  aliases = lib.concatMapAttrs (
    host: system:
    let
      inherit (system.config.backfabric) access network;
    in
    {
      ${host} = {
        HostName = network.ipv4.address;
        Port = access.ssh.port;
        HostKeyAlias = host;
      };
      "${host}-initrd" = {
        HostName = network.ipv4.address;
        Port = access.initrdSsh.port;
        HostKeyAlias = "${host}-initrd";
      };
    }
  ) nixosConfigurations;

  # With `HostKeyAlias`, ssh looks up the alias instead of `[address]:port`.
  knownHosts = pkgs.writeText "fleet-known-hosts" (
    lib.concatStrings (
      lib.mapAttrsToList (
        host: system:
        let
          inherit (system.config.backfabric) access;
        in
        ''
          ${host} ${lib.trim access.hostKey.publicKey}
          ${host}-initrd ${lib.trim access.initrdSsh.publicKey}
        ''
      ) nixosConfigurations
    )
  );

  hostBlock = patterns: options: ''
    Host ${lib.concatStringsSep " " patterns}
    ${lib.concatStrings (lib.mapAttrsToList (name: value: "  ${name} ${toString value}\n") options)}'';

  # ssh uses the first value it obtains for each option, so the fleet blocks
  # come first and only add to the user's configuration for other hosts.
  # `-F` skips both the user and the system-wide file, hence both includes.
  sshConfig = pkgs.writeText "fleet-ssh-config" ''
    ${lib.concatStrings (lib.mapAttrsToList (alias: hostBlock [ alias ]) aliases)}
    ${lib.optionalString (aliases != { }) (
      hostBlock (lib.attrNames aliases) {
        User = "root";
        UserKnownHostsFile = knownHosts;
        GlobalKnownHostsFile = "none";
        StrictHostKeyChecking = "yes";
        UpdateHostKeys = "no";
      }
    )}
    Match all
      Include ~/.ssh/config
      Include /etc/ssh/ssh_config
  '';

  # Found first in PATH by every tool that runs `ssh`: nix (ssh:// and
  # ssh-ng:// stores), nixos-rebuild, nixos-anywhere. It only adds the
  # generated config; the client is the operator machine's own: the next
  # `ssh` in PATH after the wrapper's directory (e.g. Apple's on macOS, which
  # understands its own options such as UseKeychain).
  ssh = pkgs.writeShellApplication {
    name = "ssh";
    text = ''
      self=''${BASH_SOURCE[0]}
      IFS=: read -r -a dirs <<<"$PATH"
      start=0
      for i in "''${!dirs[@]}"; do
        if [[ ''${dirs[i]}/ssh -ef $self ]]; then
          start=$((i + 1))
          break
        fi
      done
      for dir in "''${dirs[@]:start}"; do
        if [[ -x $dir/ssh && ! $dir/ssh -ef $self ]]; then
          exec "$dir/ssh" -F ${sshConfig} "$@"
        fi
      done
      echo "ssh (fleet shell): no ssh client in PATH after the wrapper; install OpenSSH" >&2
      exit 127
    '';
  };
in
pkgs.mkShellNoCC {
  packages = [
    ssh
    pkgs.nixos-anywhere
    pkgs.nixos-rebuild
    pkgs.sops
    pkgs.ssh-to-age
    (pkgs.callPackage ./install.nix { })
  ];
}
