# GitOps with Flux for agent workloads

The agents' workloads are not part of the hosts' NixOS configuration. Nix installs the platform (k3s, OpenBao, and Flux itself) and points [Flux](https://fluxcd.io) at one directory of the private fleet repository, `agents/` in the template; Flux applies that directory to the cluster and prunes what is removed from it. Flux's manifests are generated at build time by `flux install --export` of the nixpkgs `fluxcd` package, so the Flux version is pinned with nixpkgs and nothing needs the network at evaluation, and deployed from the k3s manifests directory: source-controller, kustomize-controller, and helm-controller (charts, e.g. External Secrets Operator), without notification and image automation controllers. Flux reads the repository over HTTPS with a fine-grained GitHub personal access token that can only read this one repository (Contents: Read-only), provided by the operator and stored in sops; the Secret is rendered by sops-nix outside the Nix store. Agents get no write access to the repository until a separate decision. Implemented by the `flux` subsystem.

## Trust model

Everything under the synced directory is untrusted: agents may come to write it, and review alone is not a boundary. The Kustomization does not act as kustomize-controller (cluster-admin) but impersonates a dedicated service account, `flux-system/flux-agents`, and both controllers run with Flux's multi-tenancy lockdown flags (`--default-service-account=default`, so an object without a service account gets no rights; `--no-cross-namespace-refs`; `--no-remote-bases`). The account's RBAC is an allowlist: Namespaces, ServiceAccounts, ConfigMaps, Services, Deployments, Jobs, CronJobs. Excluded are Secrets (workload secrets come from OpenBao), RBAC objects (they grant rights), NetworkPolicies (additive: one more can only allow more traffic), ResourceQuotas and LimitRanges (platform limits), storage, bare Pods, Endpoints and EndpointSlices, CRDs, admission configuration, every other cluster-scoped kind, and Flux's own kinds (they would sync other sources). RBAC cannot restrict names, so a ValidatingAdmissionPolicy confines the account's writes, deletes included, to namespaces named `agent-*` and keeps their Pod Security at `restricted`: the level labels may only say `restricted`, version pins are refused.

Not decided yet: the platform defaults of an agent namespace (default-deny egress NetworkPolicy, ResourceQuota, LimitRange). The synced directory cannot create them, and generating them for every `agent-*` namespace is decided with the egress broker. Until then an agent namespace has open egress and no quota.

## Considered Options

- Argo CD: heavier (more components, a UI and its own API server, its own user management), so a larger attack surface for a cluster that exposes nothing.
- A separate repository for workloads: a second access path to manage; one repository keeps one token and one review flow.
- An SSH deploy key: GitHub steers long-lived machine access to GitHub Apps; a read-only fine-grained token is scoped as tightly and is a plain HTTPS password for Flux. A GitHub App (short-lived installation tokens, not tied to a user) may replace the token later.
- Nix applying the workloads (k3s manifests): every workload change becomes a host deployment, and k3s does not delete what is removed from the manifests directory.
- Flux's release `install.yaml` fetched with a hash: a second version to bump by hand, next to the CLI in nixpkgs.
- Trusting review of the synced directory, with Flux's default cluster-admin Kustomization: one merged change, by a person or an agent, would own the cluster and, through kube-system (exempt from Pod Security), the host.
- Per-namespace Kustomizations with namespaced RoleBindings (Flux's multi-tenancy example): needs a Kustomization and a RoleBinding per agent namespace, maintained outside the synced directory; one allowlisted account confined by an admission policy lets the directory create its own `agent-*` namespaces.

## Consequences

- Whoever can push to the synced branch gets only what `flux-agents` may do: the allowed kinds in `agent-*` namespaces under Pod Security `restricted`. That still includes running arbitrary images with open egress (see above), reaching in-cluster Services, and creating ServiceAccounts in `agent-*` namespaces; an OpenBao Kubernetes auth role bound to an `agent-*` namespace is therefore reachable from the synced directory. The Flux objects in `flux-system` and the policy are managed by Nix only.
- The token is tied to the GitHub user who created it and expires as they chose; an expired token stops syncing (the GitRepository is not Ready) without affecting what runs. Replacing it restarts k3s, because k3s does not notice a changed file behind an unchanged link.
- The token is in `secrets/common.yaml`, readable by every host. Before the first agent node joins, it moves to a file only the servers can read, as the k3s token (ADR 0017) and OpenBao's secrets (ADR 0019).
- Flux's controller images are pulled from `ghcr.io/fluxcd` by tag when k3s applies the manifests, unlike k3s's own airgap images.
- Flux needs no sops or age key in the cluster: workload secrets come from OpenBao (ADR 0009), not from the repository.
