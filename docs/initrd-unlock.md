# Unlocking the disks over SSH

After every reboot the host waits in the initrd for the LUKS passphrase. The
initrd brings up the network configured by `backfabric.network` and runs an
SSH server on `backfabric.access.initrdSsh.port` that accepts the keys in
`backfabric.access.authorizedKeys`. The initrd has no firewall.

## Unlock after a reboot

In the [fleet dev shell](fleet-shell.md):

```sh
backfabric unlock <host>
```

The passphrase comes from the host's state directory while it exists
(between `backfabric keygen` and `backfabric finalize`), else from stdin: a
hidden prompt on a terminal, or a pipe, for example from a password manager:

```sh
op read "op://Fleet/node1/LUKS passphrase" | backfabric unlock node1
```

The command connects with `ssh -T <host>-initrd` (the dev shell's alias, so
the initrd's host key is checked), sends the passphrase on stdin, and runs in
the initrd's root shell:

```sh
SYSTEMD_ASK_PASSWORD_AGENT_PASSWORD=<passphrase> systemd-tty-ask-password-agent --query
```

`systemd-tty-ask-password-agent --query` answers every pending password
request in `/run/systemd/ask-password/` once and exits; with
`SYSTEMD_ASK_PASSWORD_AGENT_PASSWORD` set it sends that value instead of
asking on a terminal (systemd 258 and later; nixpkgs 26.05 has systemd 260).
No terminal is involved, so nothing is echoed. The passphrase never appears
on a command line.

All disks share one passphrase, and one run unlocks them all:
systemd-cryptsetup asks for each disk with `AcceptCached` and caches an
accepted passphrase in the kernel keyring (crypttab's `password-cache=`
defaults to `yes`, and NixOS does not change it). Requests pending at the
same time all get the passphrase from the agent; a disk that asks later
finds it in the cache.

The command does not wait for the boot. If no request is pending (the initrd
is still starting, or the disks are unlocked already), or it cannot connect,
it says so; run it again. A wrong passphrase makes systemd-cryptsetup ask
again: run it again with the right one.

Afterwards, log in to the booted system with `ssh <host>`. The initrd and the
booted system have different host keys; the fleet shell checks each against
the generated known_hosts under its own alias (`HostKeyAlias`).

### By hand

`ssh <host>-initrd`, then `systemd-tty-ask-password-agent --query` (or
`systemctl default`) prompts for the passphrase.

## The initrd host key

The initrd and its SSH host key are stored unencrypted on the ESPs, so the key
is not a secret and must differ from the host key of the booted system. It is
generated once by `backfabric keygen` (see [fleet-shell.md](fleet-shell.md))
and copied to the host with nixos-anywhere `--extra-files` at
`backfabric.access.initrdSsh.hostKey`. The key stays on the encrypted root
file system: every boot loader installation reads it from there and appends
it to the initrd, so it must not be deleted. Its public key is
`backfabric.access.initrdSsh.publicKey`.
