# Fleet dev shell for the operator machine (`lib.mkFleetShell`), see
# docs/fleet-shell.md.
#
# `pkgs`: package set of the operator machine (e.g. aarch64-darwin).
# `nixosConfigurations`: the hosts; every entry must import this flake's
# `access` and `network` subsystems. The attribute name is the SSH alias.
{ pkgs, nixosConfigurations }:
let
  inherit (pkgs) lib;

  # The facts (./facts.nix) work before the host's facter report exists, so
  # the shell evaluates as soon as every host has its `.pub` files.
  facts = lib.mapAttrs (_: import ./facts.nix) nixosConfigurations;

  # SSH options per alias. Port knocking (Stage 4) adds a `ProxyCommand` to
  # the alias of the booted system.
  aliases = lib.concatMapAttrs (host: host': {
    ${host} = {
      HostName = host'.address;
      Port = host'.sshPort;
      HostKeyAlias = host;
    };
    "${host}-initrd" = {
      HostName = host'.address;
      Port = host'.initrdPort;
      HostKeyAlias = "${host}-initrd";
    };
  }) facts;

  # With `HostKeyAlias`, ssh looks up the alias instead of `[address]:port`.
  knownHosts = pkgs.writeText "fleet-known-hosts" (
    lib.concatStrings (
      lib.mapAttrsToList (host: host': ''
        ${host} ${lib.trim host'.hostPublicKey}
        ${host}-initrd ${lib.trim host'.initrdPublicKey}
      '') facts
    )
  );

  hostBlock = patterns: options: ''
    Host ${lib.concatStringsSep " " patterns}
    ${lib.concatStrings (lib.mapAttrsToList (name: value: "  ${name} ${toString value}\n") options)}'';

  # Included by the operator's ~/.ssh/config with `Include ${PROJECT_SSH_CONFIG}`
  # as its first line (see docs/fleet-shell.md): ssh uses the first value it
  # obtains for each option, so these blocks come before the user's own
  # (e.g. `Host *`). Outside the shell the variable is unset and ssh skips
  # the Include. Only fleet aliases match here; it must not include
  # ~/.ssh/config itself (recursion), and ssh reads the user's and the
  # system-wide config on its own.
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
    )}'';
in
pkgs.mkShellNoCC {
  packages = [
    pkgs.nixos-anywhere
    pkgs.nixos-rebuild
    pkgs.sops
    pkgs.ssh-to-age
    (pkgs.callPackage ./cli { })
  ];
  # A shell hook, unlike an attribute, also reaches a shell that includes this
  # one with `inputsFrom`.
  shellHook = ''
    export PROJECT_SSH_CONFIG=${sshConfig}
  '';
}
