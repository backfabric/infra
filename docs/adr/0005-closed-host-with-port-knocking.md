# Closed host: key-only root SSH behind port knocking

Inbound traffic is closed except root SSH with keys on a non-standard port on the uplink only (ADR 0017), which port knocking (pure nftables, no daemon; not implemented yet) opens only for the knocking address; IPv4 ping is off; hosts have no IPv6 (ADR 0016). There is no separate admin user: with passwordless sudo it would add nothing. The initrd has no firewall, so its SSH port is open while the host waits for the passphrase. Knocking only hides the port from scanners; the SSH key is the security boundary.
