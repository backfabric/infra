# sops with the host SSH key as identity; .sops.yaml maintained by commands

Hosts decrypt their secrets with sops-nix using their SSH ed25519 host key as age identity, so a host needs no extra key. `.sops.yaml` is an ordinary file in the private repository: `backfabric sops init` creates it once with the admin keys (age or PGP, the operator's choice), and `backfabric sops add-host` adds each host (anchor, rule for `secrets/<host>.yaml`, entry in `secrets/common.yaml`) and re-encrypts. It is not generated from Nix, so admins can be edited by hand and no admin list lives in Nix.
