# Key-only root SSH, not hidden

Supersedes ADR 0005. Inbound traffic is closed except root SSH with keys only on a non-standard port; IPv4 ping is off and hosts have no IPv6 (ADR 0016). There is no separate admin user: with passwordless sudo it would add nothing. The initrd has no firewall, so its SSH port is open while the host waits for the passphrase. sshd stays visible from the internet; the SSH key is the security boundary, and a vulnerability in sshd itself is answered with a prompt update (`backfabric deploy`). Pods can still reach sshd through `cni0` (issue #38).

## Considered Options

- Port knocking: no NixOS module exists for knockd or fwknop, so it needs hand-written nftables rules or a self-wired daemon, which is fragile in the one path that keeps the host reachable.
- SSH only through WireGuard: hides sshd with real authentication, but a broken tunnel locks the operator out until Rescue; rejected for that risk.
- sshguard: bans addresses after failed logins; with key-only login there is nothing to guess, it barely helps against an sshd exploit (one connection suffices), and it can ban the operator.
