# Install command of the fleet dev shell, see docs/fleet-shell.md. Also a
# flake package, so that a host can be installed before its public keys
# exist (the dev shell needs them).
{
  writeShellApplication,
  coreutils,
  gitMinimal,
  jq,
  nixos-anywhere,
  sops,
  ssh-to-age,
}:
writeShellApplication {
  name = "backfabric-install";
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
  ];
  text = ''
    factsNix=${./facts.nix}
  ''
  + builtins.readFile ./install.sh;
}
