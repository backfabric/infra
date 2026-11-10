# LUKS unlocked over SSH in the initrd only

After every boot the operator sends the LUKS passphrase over SSH to the systemd initrd (own port, key-only, own host key; `backfabric unlock`). Every reboot therefore waits for a human, which is accepted.

## Considered Options

- Tang/clevis: rejected. Tang does not authenticate its clients; anyone who can reach the Tang server with the disk can unlock it, so its protection reduces to network reachability.
- TPM2: absent or unreliable on Hetzner bare metal.
