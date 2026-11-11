# GitOps with Flux for agent workloads

The agents' workloads are not part of the hosts' NixOS configuration. Nix installs the platform (k3s, OpenBao, and Flux itself) and points [Flux](https://fluxcd.io) at one directory of the private fleet repository, `agents/` in the template; Flux applies that directory to the cluster and prunes what is removed from it. Flux's manifests are generated at build time by `flux install --export` of the nixpkgs `fluxcd` package, so the Flux version is pinned with nixpkgs and nothing needs the network at evaluation, and deployed from the k3s manifests directory: source-controller, kustomize-controller, and helm-controller (charts, e.g. External Secrets Operator), without notification and image automation controllers. Flux reads the repository over HTTPS with a fine-grained GitHub personal access token that can only read this one repository (Contents: Read-only), provided by the operator and stored in sops; the Secret is rendered by sops-nix outside the Nix store. Agents get no write access to the repository until a separate decision. Implemented by the `flux` subsystem.

## Considered Options

- Argo CD: heavier (more components, a UI and its own API server, its own user management), so a larger attack surface for a cluster that exposes nothing.
- A separate repository for workloads: a second access path to manage; one repository keeps one token and one review flow.
- An SSH deploy key: GitHub steers long-lived machine access to GitHub Apps; a read-only fine-grained token is scoped as tightly and is a plain HTTPS password for Flux. A GitHub App (short-lived installation tokens, not tied to a user) may replace the token later.
- Nix applying the workloads (k3s manifests): every workload change becomes a host deployment, and k3s does not delete what is removed from the manifests directory.
- Flux's release `install.yaml` fetched with a hash: a second version to bump by hand, next to the CLI in nixpkgs.

## Consequences

- Whoever can push to the synced branch controls the cluster: kustomize-controller and helm-controller run as cluster-admin (Flux's default), and can create pods in kube-system, which Pod Security exempts. Branch protection and review in the private repository are the control; restricting Flux to service accounts per tenant is possible later.
- The token is tied to the GitHub user who created it and expires as they chose; an expired token stops syncing (the GitRepository is not Ready) without affecting what runs. Replacing it restarts k3s, because k3s does not notice a changed file behind an unchanged link.
- The token is in `secrets/common.yaml`, readable by every host. Before the first agent node joins, it moves to a file only the servers can read, as the k3s token (ADR 0017) and OpenBao's secrets (ADR 0019).
- Flux's controller images are pulled from `ghcr.io/fluxcd` by tag when k3s applies the manifests, unlike k3s's own airgap images.
- Flux needs no sops or age key in the cluster: workload secrets come from OpenBao (ADR 0009), not from the repository.
