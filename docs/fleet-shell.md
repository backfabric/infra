# Fleet dev shell and installing a host

The private repository builds a dev shell from its `nixosConfigurations`. In
that shell, `ssh`, `nix copy`, `nixos-rebuild`, and `nixos-anywhere` know
every host by name, with its address, ports, and host keys. Nothing is
written to `~/.ssh`, and client keys are not configured: ssh authenticates
with whatever the operator machine provides (default keys, agent, ...).

## Setup in the private repository

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    backfabric = {
      url = "github:backfabric/infra";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, backfabric }:
    {
      nixosConfigurations.node1 = nixpkgs.lib.nixosSystem {
        modules = [
          backfabric.nixosModules.default
          ./hosts/node1
        ];
      };

      devShells.aarch64-darwin.default = backfabric.lib.mkFleetShell {
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        inherit (self) nixosConfigurations;
      };
    };
}
```

`lib.mkFleetShell { pkgs, nixosConfigurations }`: `pkgs` is the package set
of the operator machine (any system nixpkgs supports, e.g. aarch64-darwin or
x86_64-linux); `nixosConfigurations` are the hosts, each importing
`nixosModules.default` (or at least `access` and `network`). The attribute
name is the host's SSH alias. To leave hosts out, pass a subset.

Each host's directory holds its nixos-facter report and the public host keys
written by the install command:

```nix
# hosts/node1/default.nix
{
  hardware.facter.reportPath = ./facter.json;
  backfabric.access.hostKey.publicKey = builtins.readFile ./ssh_host_ed25519_key.pub;
  backfabric.access.initrdSsh.publicKey = builtins.readFile ./initrd_ssh_host_ed25519_key.pub;
  # ... disks, network, access ports and authorized keys
}
```

## The shell

`nix develop` provides:

- `ssh`: a wrapper that runs the operator machine's own ssh client (the next
  `ssh` in `PATH` after the wrapper, e.g. `/usr/bin/ssh` on macOS) with
  `-F <generated config>`. Being first in `PATH`, it is also used by
  `nix copy --to ssh-ng://<host>` (and `ssh://`), by `nixos-rebuild`
  (`--target-host`, `--build-host`, via ssh and `nix-copy-closure`), and by
  `nixos-anywhere` (whose own openssh comes last in its `PATH`, after the
  operator's).
- `nixos-anywhere`, `nixos-rebuild` (nixos-rebuild-ng, also on macOS),
  `sops`, `ssh-to-age`, and `backfabric-install`.

The generated config defines per host:

| Alias           | Address                       | Port                           | Host key                  |
| --------------- | ----------------------------- | ------------------------------ | ------------------------- |
| `<host>`        | `backfabric.network.ipv4.address` | `backfabric.access.ssh.port`       | `access.hostKey.publicKey`   |
| `<host>-initrd` | `backfabric.network.ipv4.address` | `backfabric.access.initrdSsh.port` | `access.initrdSsh.publicKey` |

with `User root`, `HostKeyAlias <alias>` (so the two host keys of one address
are kept apart), a generated known_hosts file in the Nix store,
`GlobalKnownHostsFile none`, `StrictHostKeyChecking yes`, and
`UpdateHostKeys no`. ssh uses the first value it finds for each option; the
fleet blocks come first, then `~/.ssh/config` and `/etc/ssh/ssh_config` are
included for everything else (`-F` would otherwise skip both). For a fleet
host, the user's configuration can still add options the fleet blocks do not
set.

### Client keys

The generated config sets no client key options. ssh uses the default keys
(`~/.ssh/id_ed25519`, ...) and the keys of a running ssh-agent. For a key
with another name, add the fleet aliases to your own `~/.ssh/config`:

```
Host node1 node1-initrd
  IdentityFile ~/.ssh/id_fleet
  # Optional: offer only this key, not the agent's other keys.
  IdentitiesOnly yes
```

This applies because the generated config includes `~/.ssh/config` for every
host and sets neither `IdentityFile` nor `IdentitiesOnly` itself.

Examples:

```sh
ssh node1                     # booted system
ssh node1-initrd              # initrd, to unlock the disks
nix copy --to ssh-ng://node1 /nix/store/...
# macOS cannot build the x86_64-linux system: build on the host itself.
nixos-rebuild switch --flake .#node1 --target-host node1 --build-host node1
```

A host's key changes only when it is reinstalled; re-enter the shell after
committing the new `.pub` files.

## Installing a host

Boot the server into the Hetzner Rescue system with your SSH key, write the
host's configuration (disks, network, access, `hardware.facter.reportPath`,
the two `publicKey` options as above), and run from the root of the private
repository:

```sh
backfabric-install node1
```

Until a host has its report and public keys, its configuration cannot be
fully evaluated, and neither can the dev shell. For a new host, run the
install command without the shell, from the same pinned input (named
`backfabric` here):

```sh
nix run --inputs-from . backfabric#backfabric-install -- node1
```

The command:

1. Evaluates only the address, `backfabric.access.initrdSsh.hostKey`, and
   `hardware.facter.reportPath` of `nixosConfigurations.node1`
   (`fleet/facts.nix`), so a missing report (and with it the platform, which a
   real host takes from its report) or missing `.pub` files do not matter.
2. Connects to the Rescue system (`root@<address>`, port 22) with a temporary
   known_hosts and `StrictHostKeyChecking accept-new`, and prints the host
   key fingerprints to compare with the ones the Hetzner Robot shows when
   activating Rescue. nixos-anywhere disables host key checking itself
   (`StrictHostKeyChecking=no` before any `--ssh-option`); the command puts an
   ssh in front of it in `PATH` that checks against the pinned key. The kexec
   installer keeps the Rescue host keys.
3. Generates the ed25519 host key (`/etc/ssh/ssh_host_ed25519_key`) and the
   initrd host key (at `initrdSsh.hostKey`) into a temporary `--extra-files`
   tree, and writes `ssh_host_ed25519_key.pub` and
   `initrd_ssh_host_ed25519_key.pub` into the directory of the facter report.
   The private keys never enter the repository or the Nix store.
4. Prints the host's age recipient (`ssh-to-age`) and waits until it appears
   in `.sops.yaml`; adding it to the right `creation_rules` is up to you (see
   [secrets.md](secrets.md)). Then runs `sops updatekeys -y` on every
   sops-encrypted file tracked by git. Without `.sops.yaml` this step is
   skipped.
5. Reads the LUKS passphrase twice into a temporary file (mode 600) for
   `--disk-encryption-keys /tmp/disk-encryption.key`.
6. Runs nixos-anywhere with `--flake .#node1 --build-on remote --extra-files`.
   If the facter report is missing, nixos-anywhere generates it after the
   kexec (`--generate-hardware-config nixos-facter`), before evaluating the
   flake.
7. Deletes the temporary directory on exit, also on failure.

New files are added to git with `--intent-to-add`: a flake in a git
repository only sees files in the index, and this makes them visible without
staging their content. Commit them afterwards, with `.sops.yaml` and the
re-encrypted files.

If the command fails, the generated private keys are gone. Unless the host
was installed nevertheless, delete the two `.pub` files and remove the
recipient from `.sops.yaml` before retrying. To reinstall a host, do the same
first: the command refuses to overwrite existing `.pub` files.

After the install, the host waits for the passphrase on every boot; see
[initrd-unlock.md](initrd-unlock.md).
