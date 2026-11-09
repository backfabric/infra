# Unlocking the disks over SSH

After every reboot the host waits in the initrd for the LUKS passphrase. The
initrd brings up the network configured by `backfabric.network` and runs an
SSH server on `backfabric.access.initrdSsh.port` that accepts the keys in
`backfabric.access.authorizedKeys`. The initrd has no firewall.

## Unlock after a reboot

In the [fleet dev shell](fleet-shell.md):

```sh
ssh <host>-initrd
systemctl default
```

`systemctl default` prompts for the passphrase and then continues the boot,
which ends the SSH session. All disks share one passphrase; systemd tries an
entered passphrase on the other disks as well, so answer any further prompt
with the same passphrase. Alternatively, `systemd-tty-ask-password-agent`
answers the pending prompts without waiting for the boot.

Afterwards, log in to the booted system with `ssh <host>`. The initrd and the
booted system have different host keys; the fleet shell checks each against
the generated known_hosts under its own alias (`HostKeyAlias`).

## The initrd host key

The initrd and its SSH host key are stored unencrypted on the ESPs, so the key
is not a secret and must differ from the host key of the booted system. It is
generated once at install time by the install command (see
[fleet-shell.md](fleet-shell.md)) and copied to the host with nixos-anywhere
`--extra-files` at `backfabric.access.initrdSsh.hostKey`. The key stays on the
encrypted root file system: every boot loader installation reads it from there
and appends it to the initrd, so it must not be deleted. Its public key is
`backfabric.access.initrdSsh.publicKey`.
