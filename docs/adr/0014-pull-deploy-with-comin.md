# Pull-based deployment with comin and last-known-good rollback

Hosts deploy themselves: comin polls the private repository on GitHub (read-only deploy key) and switches to new commits, because the operator may have no machine at hand to push from; changes go through GitHub only. After each deployment a health check (sshd listening, the SSH firewall rule present, default route, `git fetch` works) records the generation as last known good; on failure the host switches back to it and does not apply the failed commit again. Breakage that only shows after a reboot (boot loader, initrd) is recovered by hand from Rescue. Not implemented yet.

## Considered Options

- deploy-rs or `nixos-rebuild --target-host` from the operator machine: magic rollback, but needs a machine with SSH access for every change.
