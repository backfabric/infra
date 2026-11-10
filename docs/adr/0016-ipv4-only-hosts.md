# IPv4-only hosts

Hosts use only their main IPv4 address; the /64 that Hetzner assigns to every server is left unused. IPv6 is disabled in the booted system with the standard `networking.enableIPv6 = false` (sysctl `disable_ipv6`), and the uplink's systemd-networkd unit turns off link-local addressing and router advertisements in both stages, since the sysctl does not reach the initrd. Like the IPv4-only cluster network (ADR 0007), every address family left out is one less path in and out to firewall and audit. Re-enabling IPv6 later needs no reinstall.

## Considered Options

- Kernel parameter `ipv6.disable=1`: removes the IPv6 stack entirely, but software that expects `AF_INET6` or `ip6tables` to exist (k3s, kube-router, containerd) may fail; the sysctl gives the same external result.
