# The operator command `backfabric` of the fleet dev shell, see
# docs/fleet-shell.md. Also a flake package, so that it runs before a host
# has its public keys (the dev shell needs them).
#
# One script: the shared helpers, one file per subcommand, and the
# dispatcher, concatenated so that shellcheck checks them together.
{
  lib,
  writeShellApplication,
  coreutils,
  gitMinimal,
  jq,
  nixos-anywhere,
  sops,
  ssh-to-age,
  yq-go,
}:
writeShellApplication {
  name = "backfabric";
  # Deliberately not listed: `nix` (the operator's own Nix evaluates the
  # private repository) and openssh (ssh and ssh-keygen are the operator's
  # own client, as in the fleet shell's ssh wrapper).
  runtimeInputs = [
    coreutils
    gitMinimal
    jq
    nixos-anywhere
    sops
    ssh-to-age
    yq-go
  ];
  text = ''
    factsNix=${../facts.nix}
  ''
  + lib.concatMapStrings builtins.readFile [
    ./lib.sh
    ./sops-init.sh
    ./sops-add-host.sh
    ./install.sh
    ./backfabric.sh
  ];
}
