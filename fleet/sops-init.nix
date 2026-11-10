# `.sops.yaml` creation command of the fleet dev shell, see docs/secrets.md.
# Also a flake package, so that it runs before the hosts have public keys
# (the dev shell needs them).
{ writeShellApplication }:
writeShellApplication {
  name = "backfabric-sops-init";
  text = builtins.readFile ./sops-init.sh;
}
