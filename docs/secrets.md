# Secrets

Secrets are stored encrypted with [sops](https://github.com/getsops/sops) in
the private repository and decrypted on the host by
[sops-nix](https://github.com/Mic92/sops-nix) during activation.

## Model

- Every host decrypts with its SSH ed25519 host key,
  `/etc/ssh/ssh_host_ed25519_key`. The matching age recipient is derived
  from the public key with `ssh-to-age`. No other key is used on the host.
- The host key is generated before the install and copied to the host with
  nixos-anywhere `--extra-files`, so the first boot can already decrypt.
  `backfabric keygen` and `backfabric install` do this (see
  [fleet-shell.md](fleet-shell.md)). sshd uses the same key.
- Admins decrypt and edit secrets with their own keys. Which kind of key
  (age, PGP, ...) and where it lives is the private repository's choice; the
  commands here never create or look for admin keys (sops finds them). They
  only add and replace host recipients and add missing cluster-wide secrets.
- Two kinds of sops files: `secrets/common.yaml`, readable by every host, and
  `secrets/<host>.yaml`, readable by that host only. The private repository
  sets `backfabric.secrets.commonFile` to `secrets/common.yaml` for every
  host (the template's `mkHost` does), and `sops.defaultSopsFile` to the
  host's own file once it has one. Subsystems declare the secrets they need
  as `sops.secrets.<name>`, cluster-wide ones with
  `sopsFile = config.backfabric.secrets.commonFile`. Every host needs
  `secrets/common.yaml`: it holds the k3s cluster token (see
  [below](#cluster-wide-secrets)).

## `.sops.yaml`

`.sops.yaml` is a normal file in the root of the private repository. It is
created once, with the admin keys, and the fleet dev shell adds the hosts to
it:

```sh
backfabric sops init --age age1... --pgp 0123456789ABCDEF0123456789ABCDEF01234567
backfabric sops add-host node1
backfabric sops add-host node2
```

`backfabric sops init` takes any number of `--age <recipient>` and
`--pgp <fingerprint>` (40 hex digits, no spaces), at least one, and refuses
to overwrite an existing `.sops.yaml`. The result, after adding two hosts:

```yaml
# sops configuration, created by backfabric sops init. backfabric sops add-host
# maintains the hosts: the keys host_<host>, the rules for secrets/<host>.yaml,
# and the hosts in the rule for secrets/common.yaml. The admin keys (admin_<n>)
# may be edited by hand; a new admin key belongs in every rule.
keys:
  - &admin_0 "age1..."
  - &admin_1 "0123456789ABCDEF0123456789ABCDEF01234567"
  - &host_node1 age1...
  - &host_node2 age1...
creation_rules:
  - path_regex: ^secrets/common\.yaml$
    key_groups:
      - age:
          - *admin_0
          - *host_node1
          - *host_node2
        pgp:
          - *admin_1
  - path_regex: ^secrets/node1\.yaml$
    key_groups:
      - age:
          - *admin_0
          - *host_node1
        pgp:
          - *admin_1
  - path_regex: ^secrets/node2\.yaml$
    key_groups:
      - age:
          - *admin_0
          - *host_node2
        pgp:
          - *admin_1
```

Every key is a YAML anchor, and the rules refer to it with aliases, so a key
is written once. The admin keys may be edited by hand, comments included: add
a new admin as `&admin_<n>` under `keys` and as `*admin_<n>` in every rule,
then run `sops updatekeys` on every file. `backfabric sops add-host` keeps
such edits.

### Admin keys

sops finds the admin keys the usual way (`SOPS_AGE_KEY_FILE`, the GnuPG
keyring, ...). The private repository can set them in its own dev shell,
which adds to the fleet shell:

```nix
devShells.aarch64-darwin.default =
  let
    pkgs = nixpkgs.legacyPackages.aarch64-darwin;
    fleetShell = backfabric.lib.mkFleetShell {
      inherit pkgs;
      inherit (self) nixosConfigurations;
    };
  in
  pkgs.mkShellNoCC {
    inputsFrom = [ fleetShell ];
    shellHook = ''
      export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/fleet.txt
    '';
  };
```

## Adding a host

```sh
backfabric sops add-host node1
```

run from the root of the private repository:

1. Evaluates `backfabric.access.hostKey.publicKey` of
   `nixosConfigurations.node1` (`nix/fleet/facts.nix`; a missing facter report
   does not matter, the `.pub` file must exist) and converts it with
   `ssh-to-age`.
2. Adds the key `&host_node1`, a rule for `secrets/node1.yaml` with every
   admin key (`admin_*`; `age1...` and `ssh-...` values under `age`, PGP
   fingerprints under `pgp`) and the host, and the host to the age keys of
   the `secrets/common.yaml` rule. Edits are made with
   [yq](https://github.com/mikefarah/yq), which keeps anchors, aliases,
   comments, and hand-edited admin keys.
3. Runs `sops updatekeys -y` on `secrets/common.yaml` and
   `secrets/node1.yaml` if they exist, which needs an admin key.

If the host is already in `.sops.yaml` with the same key, the command does
nothing. If it is there with another key, the command refuses; with
`--replace` it replaces the value of `&host_node1`, which every rule refers to,
and re-encrypts the files as above.

`backfabric keygen` writes the host's `.pub` files; add the host to
`.sops.yaml` right after it, before `backfabric install`, which refuses
while the host is missing from `.sops.yaml` or is there with another key.
Host names may contain letters, digits, `-` and `_`; `common` is reserved.

In a new private repository, without hosts, the dev shell evaluates and
`sops init` runs in it. If the shell does not evaluate (a host without `.pub`
files), the commands also run on their own,
from the private repository's pinned input (named `backfabric` here):

```sh
nix run --inputs-from . backfabric -- sops init --age age1...
```

Commit `.sops.yaml` and the re-encrypted files before deploying the host.

## Cluster-wide secrets

`secrets/common.yaml` holds the secrets every host shares. Today that is
one:

| Key | Used by | Value |
| --- | ------- | ----- |
| `k3s-token` | `k3s` subsystem, `services.k3s.tokenFile` (`/run/secrets/k3s-token`, root, mode 0400) | 32 random bytes, hex |

`backfabric keygen` creates and fills it: with a host (`keygen node1`)
before generating the host's keys, without one (`keygen`) on its own, for
hosts that are already installed. It generates only the secrets that are
missing and never changes an existing value:

- No `.sops.yaml`: skipped, with a message.
- No `secrets/common.yaml`: created with every secret, encrypted for the
  keys of its rule in `.sops.yaml` (the admins and the hosts added so far).
  This needs no admin key; the values go to sops on stdin and are never
  written unencrypted. The file is added to git with `--intent-to-add`.
- The file exists: the key names of a sops file are not encrypted, so the
  command sees which secrets are missing without a key, and adds each with
  `sops set --value-stdin`, which needs an admin key.

Hosts added later get the file through `backfabric sops add-host`, which
re-encrypts it for them.

The k3s token must never change: k3s encrypts its bootstrap data in etcd
with it, so a cluster, and an etcd snapshot restored on a new server, only
works with the original token. Keep the file's history; changing the token
means resetting the cluster.

## Rotating a host key

1. Generate the new key pair locally, outside the repository:
   `ssh-keygen -t ed25519 -N "" -C node1 -f <dir>/ssh_host_ed25519_key`.
2. Replace the host's `ssh_host_ed25519_key.pub` in the private repository
   with the new public key and run `backfabric sops add-host --replace node1`.
   The host cannot decrypt the re-encrypted files yet, but it only reads them
   at the next deployment.
3. From the dev shell you are in (it still knows the old host key), install
   the new private key on the host at `/etc/ssh/ssh_host_ed25519_key` (mode
   `0600`) and the public key next to it, restart sshd, and delete the local
   private key.
4. Commit, re-enter the dev shell (new known_hosts), and deploy.

If the old key may have leaked, also run `sops rotate -i <file>` to replace
the data key, and change the secret values themselves: the git history still
holds them encrypted to the old key.

Reinstalling a host generates a new host key as well (`backfabric keygen`);
run `backfabric sops add-host --replace <host>` before `backfabric install`.

## Losing a host key

Without its host key the host cannot decrypt anything: sops-nix cannot
install the declared secrets, and the services that need them fail. The
secrets are not lost: the admins can still decrypt them. Generate a new host
key, replace the host's `.pub` file, run `backfabric sops add-host --replace
<host>`, copy the new key to the host (for example from the Hetzner Rescue
system after unlocking the disks), and deploy again. If the key may have
leaked rather than been lost, follow the last paragraph of the previous
section.
