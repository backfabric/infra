# Secrets

Secrets are stored encrypted with [sops](https://github.com/getsops/sops) in
the private repository and decrypted on the host by
[sops-nix](https://github.com/Mic92/sops-nix) during activation.

## Model

- Every host decrypts with its SSH ed25519 host key,
  `/etc/ssh/ssh_host_ed25519_key`. The matching age recipient is derived
  from the public key with `ssh-to-age`. No other key is used on the host.
- The host key is generated before the install and copied to the host with
  nixos-anywhere `--extra-files`, so the first boot can already decrypt. The
  install command (see [fleet-shell.md](fleet-shell.md)) does this. sshd
  uses the same key.
- Admins decrypt and edit secrets with their own keys. Which kind of key
  (age, SSH, PGP, ...) is the private repository's choice; these modules
  only care about the host recipients.
- The private repository sets `sops.defaultSopsFile` (e.g.
  `./secrets.yaml`). Subsystems declare the secrets they need as
  `sops.secrets.<name>`. A host without secrets needs no sops file.

## `.sops.yaml`

Each file must be encrypted to the admin keys and to every host that needs
it. For example, with one admin age key and two hosts:

```yaml
keys:
  - &admin age1...    # placeholder: the admin recipient(s), of any key type sops supports
  - &node1 age1...    # ssh-to-age of node1's host key
  - &node2 age1...    # ssh-to-age of node2's host key
creation_rules:
  - path_regex: secrets\.yaml$
    key_groups:
      - age:
          - *admin
          - *node1
          - *node2
```

## Adding a host

The install command prints the new host's recipient, waits until you have
added it to the `creation_rules` of every file the host needs, and then
re-encrypts the data keys of all sops-encrypted files (needs an admin key).
By hand, the recipient comes from the public host key:

```sh
ssh-to-age < ssh_host_ed25519_key.pub
sops updatekeys secrets.yaml
```

Commit before deploying the host.

## Rotating a host key

1. Generate the new key pair locally and add its recipient to `.sops.yaml`
   next to the old one; `sops updatekeys`, deploy. The host still decrypts
   with the old key.
2. Install the new private key on the host at
   `/etc/ssh/ssh_host_ed25519_key` (mode `0600`) and the public key next to
   it, then restart sshd. Replace the host's `ssh_host_ed25519_key.pub` in
   the private repository, which updates `hostKey.publicKey` and with it the
   known_hosts of the fleet dev shell.
3. Remove the old recipient from `.sops.yaml`; `sops updatekeys`, deploy.

If the old key may have leaked, also run `sops rotate -i <file>` to replace
the data key, and change the secret values themselves: the git history still
holds them encrypted to the old key.

## Losing a host key

Without its host key the host cannot decrypt anything: sops-nix cannot
install the declared secrets, and the services that need them fail. The
secrets are not lost: the admins can still decrypt them. Generate a new host
key, replace the host's recipient in `.sops.yaml`, `sops updatekeys`, copy
the new key to the host (for example from the Hetzner Rescue system after
unlocking the disks), and deploy again. If the key may have leaked rather
than been lost, follow the last paragraph of the previous section.
