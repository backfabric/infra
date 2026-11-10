# Fleet dev shell and installing a host

The private repository builds a dev shell from its `nixosConfigurations`. In
that shell, every SSH client of the operator machine (`ssh`, `scp`, `sftp`,
`rsync`, `git`, `nix copy`, `nixos-rebuild`, `nixos-anywhere`) knows every
host by name, with its address, ports, and host keys. The shell only exports
`PROJECT_SSH_CONFIG`, the path of a generated SSH config; one line in your
`~/.ssh/config` includes it. Nothing is written to `~/.ssh` by this
repository, and client keys are not configured: ssh authenticates with
whatever the operator machine provides (default keys, agent, ...).

## One-time setup of ~/.ssh/config

Make this the first line of `~/.ssh/config`, once per operator machine (it
works for any project whose dev shell exports `PROJECT_SSH_CONFIG`):

```
Include ${PROJECT_SSH_CONFIG}
```

OpenSSH expands environment variables in `Include` paths (ssh_config(5),
`Include`); when the variable is unset, the line includes nothing.

- Why first: ssh uses the first value it obtains for each option. Above your
  own blocks (e.g. `Host *` with `User` or `UserKnownHostsFile`), the fleet
  blocks decide the user, port, and host key checking of fleet aliases. The
  generated config only matches fleet aliases, so it changes nothing for
  other hosts.
- Inside the dev shell, the aliases below resolve for every tool that runs
  ssh, including `scp` and `sftp` with a built-in ssh path and
  `/usr/bin/ssh`.
- Outside the shell, or without the line, an alias like `node1` is an
  ordinary host name: ssh resolves it through DNS (usually failing) and
  checks host keys against your personal `~/.ssh/known_hosts`, not the
  fleet's. `backfabric unlock` and `finalize` check with `ssh -G` that the
  alias resolves through the fleet config and refuse otherwise.

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

Each host's directory holds its nixos-facter report (written by
`backfabric probe`) and the public host keys (written by `backfabric keygen`):

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

- `PROJECT_SSH_CONFIG`: the generated SSH config in the Nix store, exported
  by the shell hook (which also reaches a shell that includes this one with
  `inputsFrom`).
- `nixos-anywhere`, `nixos-rebuild` (nixos-rebuild-ng, also on macOS),
  `sops`, `ssh-to-age`, and `backfabric`, the command of this repository
  (see [below](#the-backfabric-command)). `ssh` itself is the operator
  machine's own client.

The generated config defines per host:

| Alias           | Address                       | Port                           | Host key                  |
| --------------- | ----------------------------- | ------------------------------ | ------------------------- |
| `<host>`        | `backfabric.network.ipv4.address` | `backfabric.access.ssh.port`       | `access.hostKey.publicKey`   |
| `<host>-initrd` | `backfabric.network.ipv4.address` | `backfabric.access.initrdSsh.port` | `access.initrdSsh.publicKey` |

with `User root`, `HostKeyAlias <alias>` (so the two host keys of one address
are kept apart), a generated known_hosts file in the Nix store,
`GlobalKnownHostsFile none`, `StrictHostKeyChecking yes`, and
`UpdateHostKeys no`. It does not include `~/.ssh/config` or
`/etc/ssh/ssh_config`: ssh reads both itself, and including `~/.ssh/config`
from a file it includes would recurse. For a fleet host, your own
configuration can still add options the fleet blocks do not set.

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

This applies because ssh reads the rest of `~/.ssh/config` for fleet
aliases too, and the generated config sets neither `IdentityFile` nor
`IdentitiesOnly` itself.

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

The shell reads only a few options of each host (address, ports, public
keys; `fleet/facts.nix`), without the module system's full checks, so it
evaluates as soon as every host has its two `.pub` files, even before the
host's facter report exists.

## The `backfabric` command

`backfabric` has one subcommand per step, in the order a new fleet and a new
host need them (`backfabric help`):

- `backfabric sops init (--age <recipient> | --pgp <fingerprint>)...`: creates
  `.sops.yaml` with the admin keys, once; see [secrets.md](secrets.md).
- `backfabric keygen <host>`: generates the host's keys and LUKS passphrase.
- `backfabric sops add-host [--replace] <host>`: adds a host to `.sops.yaml`
  and re-encrypts its files; see [secrets.md](secrets.md).
- `backfabric probe <host>`: boots the server into the NixOS installer and
  writes its hardware report.
- `backfabric install <host>`: installs the host.
- `backfabric unlock <host>`: sends the LUKS passphrase to the initrd.
- `backfabric finalize <host>`: checks the installed host and deletes its
  local secrets.
- `backfabric help [<command>]`: shows this list, or the help of a command
  (e.g. `backfabric help sops add-host`). Every command also takes `-h` and
  `--help`.

Run it from the root of the private repository. A host in
`nixosConfigurations` without its `.pub` files breaks the evaluation of the
dev shell, so `backfabric keygen` for a newly added host runs without the
shell, from the private repository's pinned input (named `backfabric` here),
unless a shell entered before the host was added is still open:

```sh
nix run --inputs-from . backfabric -- keygen node1
```

Every other step runs in the dev shell.

## Installing a host

Write the host's configuration (disks, network, access,
`hardware.facter.reportPath`, the two `publicKey` options as above; the disk
ids and the MAC may be placeholders until `probe` shows the real ones),
register it in `nixosConfigurations`, and run these steps from the root of
the private repository. Each step does one thing, prints the next one, and
can be run again after a failure; none waits for a reboot.

| Step | Command | Where | Does |
| ---- | ------- | ----- | ---- |
| 1 | `backfabric keygen node1` | locally (`nix run`, see above) | host key, initrd host key and LUKS passphrase into the state directory; `.pub` files into the repository |
| 2 | `backfabric sops add-host node1` | dev shell | the host's age recipient into `.sops.yaml` (skip without `.sops.yaml`) |
| 3 | `backfabric probe node1` | server in the Hetzner Rescue system | pins the host key, kexec into the NixOS installer, facter report, hardware summary, evaluation, uplink check |
| 4 | commit | | the report, after reviewing it, and the host's other new files |
| 5 | `backfabric install node1` | server in the installer | disks, NixOS, reboot (ERASES ALL DISKS) |
| 6 | `backfabric unlock node1` | host in the initrd | the LUKS passphrase; after every boot |
| 7 | `backfabric finalize node1` | host booted | checks `ssh node1`, confirms the passphrase is stored, deletes the state directory |

### State directory

`keygen` writes the secrets of a host under installation to
`${XDG_STATE_HOME:-~/.local/state}/backfabric/<host>/` (mode 700), outside
the repository and the Nix store; `finalize` deletes it, no other command
does:

- `extra-files/`: the tree for nixos-anywhere `--extra-files`: the private
  host key `etc/ssh/ssh_host_ed25519_key` and the initrd host key at
  `backfabric.access.initrdSsh.hostKey` (both mode 600, the latter in a
  directory of mode 700);
- `luks`: the LUKS passphrase (mode 600, no trailing newline): 30 random
  characters in six groups of five (`abcdefghijkmnpqrstuvwx23456789`, about
  147 bits), without characters that are ambiguous or differ between QWERTY
  and QWERTZ keyboards;
- `known_hosts`: the host key of the server's Rescue system, pinned by
  `probe` (which creates the directory if `keygen` has not run yet).

`keygen` refuses if the state directory holds keys or a passphrase, or if
the host's `.pub` files exist.

### keygen

Evaluates only `backfabric.access.initrdSsh.hostKey` and
`hardware.facter.reportPath` of the host (`fleet/facts.nix`; the report and
the `.pub` files may be missing), generates both ed25519 keys and the
passphrase into the state directory, and writes `ssh_host_ed25519_key.pub`
and `initrd_ssh_host_ed25519_key.pub` into the directory of the facter
report. New files are added to git with `--intent-to-add`: a flake in a git
repository only sees files in the index, and this makes them visible without
staging their content.

### probe

1. On the first run, connects to `root@<address>` port 22 with a new
   known_hosts file and `StrictHostKeyChecking accept-new`, prints the key's
   SHA256 and MD5 fingerprints to compare with the ones the Hetzner Robot
   shows when activating Rescue, and keeps the file as `known_hosts` in the
   state directory on `y`. Later runs use the pinned key.
2. Runs nixos-anywhere with `--phases kexec --generate-hardware-config
   nixos-facter <reportPath> --build-on remote --no-use-machine-substituters`.
   nixos-anywhere skips the kexec if the server already runs the NixOS
   installer (its `isInstaller` fact), so probe can be run again. The
   installer keeps the Rescue system's host keys (the kexec tarball copies
   `/etc/ssh/ssh_host_*`), so the pinned key stays valid. nixos-anywhere
   disables host key checking itself (`StrictHostKeyChecking=no` before any
   `--ssh-option`); the command puts an ssh in front of it in `PATH` that
   checks against the pinned key.
3. Prints a summary of the report: platform, boot mode, CPU, RAM, the
   network controllers with their driver modules and interface names, and
   the disks with their `/dev/disk/by-id/` names and sizes.
4. Evaluates `config.system.build.toplevel.drvPath`, which runs the
   assertions that check the configuration against the report (a network
   controller with a driver module for the initrd; every
   `backfabric.disks.devices` entry among the disks of the report).
5. Checks the uplink on the server: nixos-facter reports contain no MAC
   addresses, so `ip -j link` on the installer must show an interface with
   `backfabric.network.macAddress`, and that interface's kernel module
   (`/sys/class/net/<if>/device/driver/module`) must be in the initrd
   (`boot.initrd.kernelModules` or `availableKernelModules`); otherwise the
   initrd would have no network to unlock the disks.

Nothing is written to the disks.

### install

Refuses unless the state directory has the keys (matching the `.pub` files)
and the pinned host key, the report is committed and unchanged, and, if
`.sops.yaml` exists, the host is in it with its current key. Then evaluates
the configuration, checks over SSH that the server still runs the NixOS
installer (`VARIANT_ID=installer`, the test nixos-anywhere uses) and repeats
the uplink check, and runs nixos-anywhere with `--phases
disko,install,reboot --build-on remote --extra-files <state>/extra-files
--disk-encryption-keys /tmp/disk-encryption.key <state>/luks`. It never
generates a report.

### unlock and finalize

See [initrd-unlock.md](initrd-unlock.md) for `unlock`. `finalize` runs
`ssh <host> true` (through the fleet config, so the host key from the
repository is checked),
shows where the passphrase is, asks you to store it in your password manager
and to confirm with `y`, deletes the state directory, and lists the files to
commit.

### Recovery

| Failure | Re-run |
| ------- | ------ |
| `keygen` refuses: keys or `.pub` files exist | To start over, delete the state directory and both `.pub` files, then `keygen` and `sops add-host --replace` |
| `probe` cannot connect, or the host key differs after Rescue was activated again | Activate Rescue, reset the server; if the Robot shows new fingerprints, delete `known_hosts` in the state directory; `probe` |
| `probe`: evaluation fails or the uplink check fails | Fix the configuration from the summary; `probe` (the server stays in the installer) |
| `install` refuses: no keys | `keygen` |
| `install` refuses: report not committed or changed | `probe`, review, commit |
| `install` refuses: host not in `.sops.yaml` or with another key | `sops add-host` (`--replace`) |
| `install`: server not in the installer (rebooted into Rescue or the disks) | Activate Rescue in the Robot, reset the server; `probe`, then `install` |
| `install`: nixos-anywhere fails | `install` again while the server is in the installer (it formats the disks again); otherwise as above |
| `unlock`: cannot connect, or no pending request | Wait for the initrd; `unlock` again. Wrong passphrase: `unlock` again |
| `finalize`: `ssh <host>` fails | Wait for the boot (or `unlock`); `finalize` again |

To reinstall a host, delete its `.pub` files first: `keygen` refuses to
overwrite them. After the install, the host waits for the passphrase on every
boot; see [initrd-unlock.md](initrd-unlock.md).
