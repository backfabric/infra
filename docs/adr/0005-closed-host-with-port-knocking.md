# Closed host: key-only root SSH behind port knocking

Inbound traffic is closed except root SSH with keys on a non-standard port, which port knocking (pure nftables, no daemon; not implemented yet) opens only for the knocking address; IPv4 ping is off (the upstream NixOS firewall still answers IPv6 echo requests). There is no separate admin user: with passwordless sudo it would add nothing. The initrd has no firewall, so its SSH port is open while the host waits for the passphrase. Knocking only hides the port from scanners; the SSH key is the security boundary.
