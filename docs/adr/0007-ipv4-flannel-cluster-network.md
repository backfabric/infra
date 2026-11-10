# IPv4-only cluster network on flannel

Pods and services are IPv4-only with k3s's default CIDRs (10.42.0.0/16, 10.43.0.0/16; there is a single cluster in the network), on flannel with the embedded NetworkPolicy controller; inter-node traffic goes over the nodes' public addresses, on vxlan while there is one node, with flannel's `wireguard-native` backend once a second node exists (changing the backend needs only a restart). CIDRs, dual-stack, and the CNI cannot be changed without rebuilding the cluster. Agent egress will go through an audited router (in or outside the cluster) enforced with NetworkPolicy and nftables, which flannel suffices for. The network of the first server is implemented; the egress router is not yet.

## Considered Options

- Cilium: per-pod flow logs, FQDN policies, egress gateways out of the box, but a heavier component with its own upgrade cycle; rejected until such a need is concrete.
- Hetzner vSwitch or an overlay (Tailscale, Nebula): more moving parts and tied to one location.
