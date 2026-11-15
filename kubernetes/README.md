# kubernetes/

Cluster content every fleet shares, delivered by Flux
([ADR 0027](../docs/adr/0027-flux-for-cluster-workloads.md)): one kustomize
base per component, `kubernetes/<component>/` with a `kustomization.yaml`.
A component installs an upstream Helm chart as it is published: a
HelmRepository or OCIRepository and a HelmRelease with values, never a
copy or a rewrite of the chart.

Nothing here is applied by this repository. The private repository's
`clusters/<host>/` declares a GitRepository for backfabric/infra, pinned to
the commit of its `flake.lock`, and a Flux Kustomization per component it
uses, with its host overlays; see
[Bases from backfabric/infra](../docs/flux.md#bases-from-backfabricinfra).

Empty until the first component.
