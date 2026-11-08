# Unlocking the disks over SSH

After every reboot the host waits in the initrd for the LUKS passphrase. The
initrd brings up the network configured by `backfabric.network` and runs an
SSH server on `backfabric.access.initrdSsh.port` that accepts the keys in
`backfabric.access.authorizedKeys`. The initrd has no firewall.

## Unlock after a reboot

```sh
ssh -p <initrdSsh.port> root@<host>
systemctl default
```

`systemctl default` prompts for the passphrase and then continues the boot,
which ends the SSH session. All disks share one passphrase; systemd tries an
entered passphrase on the other disks as well, so answer any further prompt
with the same passphrase. Alternatively, `systemd-tty-ask-password-agent`
answers the pending prompts without waiting for the boot.

Afterwards, log in to the booted system with `ssh -p <ssh.port> root@<host>`.
The initrd and the booted system have different host keys; ssh keeps them
apart because they listen on different ports.

## The initrd host key

The initrd and its SSH host key are stored unencrypted on the ESPs, so the key
is not a secret and must differ from the host key of the booted system. It is
generated once at install time and copied to the host with nixos-anywhere:

```sh
extra=$(mktemp -d)
install -d -m 700 "$extra/etc/secrets/initrd"
ssh-keygen -t ed25519 -N "" -C "" -f "$extra/etc/secrets/initrd/ssh_host_ed25519_key"
nixos-anywhere --extra-files "$extra" ...   # plus the usual arguments
```

The path is `backfabric.access.initrdSsh.hostKey`. The key stays on the
encrypted root file system: every boot loader installation reads it from there
and appends it to the initrd, so it must not be deleted. Record the public key
(`$extra/etc/secrets/initrd/ssh_host_ed25519_key.pub`) to verify the
fingerprint on the first unlock.
