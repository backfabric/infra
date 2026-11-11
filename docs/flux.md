# Flux

The `flux` subsystem installs [Flux](https://fluxcd.io) in the k3s cluster
and points it at one directory of the private repository
([ADR 0020](adr/0020-gitops-with-flux-for-agent-workloads.md)). Nix manages
Flux; Flux manages what is in that directory (the agents' workloads).

## What is deployed

From the k3s manifests directory, `/var/lib/rancher/k3s/server/manifests`,
in this order (k3s applies the files sorted by name and retries a file every
15 seconds until it applies):

| File | Content |
| ---- | ------- |
| `flux-install.yaml` | `flux install --export` of the nixpkgs `fluxcd` package, generated at build time: namespace `flux-system`, the CRDs, source-controller, kustomize-controller, helm-controller, and Flux's network policies |
| `flux-sync-credentials.yaml` | link to `/run/secrets/rendered/flux-sync-credentials.yaml` (root, 0400), rendered by sops-nix: the Secret `flux-system/fleet-git-credentials` with user name `git` and `flux-git-token` as password |
| `flux-sync.yaml` | GitRepository `flux-system/fleet` (`backfabric.flux.repository.url`, `branch`, fetched every `interval`) and Kustomization `flux-system/fleet` (applies `repository.path`, prunes, reverts drift every 10 minutes) |

The Flux version is the one of the `fluxcd` package in the pinned nixpkgs:
`nix flake update` can upgrade it, and the CLI on the host (`flux`) is the
same version. Images come from `ghcr.io/fluxcd`.

kustomize-controller and helm-controller run as cluster-admin (Flux's
default): whatever is pushed to the synced directory is applied with full
rights, including to kube-system, which Pod Security does not restrict.

## Checking

On the host, as root (`KUBECONFIG` points at k3s's kubeconfig):

```sh
flux check                                   # controllers and CRDs
flux get all                                 # Ready, with the fetched commit
kubectl -n flux-system get pods
kubectl -n flux-system get gitrepositories,kustomizations
flux events                                  # recent reconciliations
flux logs --level=error
```

`flux get sources git` shows the revision as `main@sha1:<commit>`; it
matches `git rev-parse origin/main` in the private repository once Flux has
fetched it. To fetch and apply now instead of waiting for the interval:

```sh
flux reconcile kustomization fleet --with-source
```

## Failures

- Token wrong, expired, or without access to the repository: the
  GitRepository is not Ready, its message carries the error from fetching
  the repository, and the Kustomization keeps what it last applied.
  Replace the token (below).
- Path missing in the commit: the Kustomization is not Ready
  (`kustomization path not found`).
- A manifest that does not apply (invalid, rejected by Pod Security or the
  NodePort policy): the Kustomization is not Ready, with the API server's
  message.
- Nothing in `flux-system` at all: k3s has not applied the manifests;
  `kubectl -n kube-system get addons` and
  `kubectl -n kube-system get events --field-selector involvedObject.kind=Addon`
  show why. A missing `flux-git-token` in `secrets/common.yaml` already
  fails the deployment, when sops-nix installs the secrets.

## Replacing the token

Create the new token as the template's README says, then in the private
repository:

```sh
sops secrets/common.yaml   # replace the value of flux-git-token
git commit -am "chore: replace the Flux token"
backfabric deploy node1
```

sops-nix renders the new Secret and restarts k3s, which applies every
manifest at start (k3s notices a changed file only by the modification time
of its link, which does not change). The pods keep running. Then
`flux reconcile source git fleet` and revoke the old token in GitHub.

## Removing workloads

Objects removed from the synced directory are deleted by the Kustomization
(`prune: true`). Removing the `flux` subsystem itself does not delete Flux
from the cluster: k3s leaves applied manifests in place
(`flux uninstall` removes it).
