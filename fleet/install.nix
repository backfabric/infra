# Install command of the fleet dev shell, see docs/fleet-shell.md. Also a
# flake package, so that a host can be installed before its public keys
# exist (the dev shell needs them).
{
  writeShellApplication,
  coreutils,
  gitMinimal,
  jq,
  nixos-anywhere,
  openssh,
  sops,
  ssh-to-age,
}:
writeShellApplication {
  name = "backfabric-install";
  # `nix` is deliberately not listed: the operator's own Nix evaluates the
  # private repository.
  runtimeInputs = [
    coreutils
    gitMinimal
    jq
    nixos-anywhere
    openssh
    sops
    ssh-to-age
  ];
  text = builtins.readFile ./install.sh;
}
