# Host command for `.sops.yaml` of the fleet dev shell, see docs/secrets.md.
# Also a flake package, and run by the install command.
{
  writeShellApplication,
  jq,
  sops,
  ssh-to-age,
  yq-go,
}:
writeShellApplication {
  name = "backfabric-sops-add-host";
  # Deliberately not listed: `nix` (the operator's own Nix evaluates the
  # private repository).
  runtimeInputs = [
    jq
    sops
    ssh-to-age
    yq-go
  ];
  text = ''
    factsNix=${./facts.nix}
  ''
  + builtins.readFile ./sops-add-host.sh;
}
