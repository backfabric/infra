# Flux

The `flux` subsystem delivers the agents, and only them, from the private
repository ([ADR 0027](adr/0027-flux-for-agents.md)). Everything else in the
cluster (the platform) is delivered by Nix, upstream Helm charts through
`services.k3s.autoDeployCharts`. Nix installs the
[Flux Operator](https://fluxoperator.dev/), Flux, the agents' namespace,
and a restricted identity; Flux applies one directory of the repository
(e.g. `agents/node1/`) into that namespace and keeps it equal to it. It is
off by default:

```nix
backfabric.flux = {
  enable = true;
  repository = {
    url = "https://github.com/<owner>/<repository>";
    path = "./agents/node1";
    branch = "main";                # the default
    tokenSecret = "flux-git-token"; # the default, in secrets/common.yaml
  };
  # The namespace is always `agents`, created by the module.
  # The default; the kagent PR adds its kinds.
  allowedResources = [ { apiGroup = ""; resources = [ "configmaps" ]; } ];
};
```

| What | Where |
| ---- | ----- |
| Flux Operator | Helm release `flux-operator` in `flux-system`, from the upstream chart `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator` 0.62.1 (k3s HelmChart `kube-system/flux-operator`, manifest `flux-operator`) |
| Flux | FluxInstance `flux-system/flux` (manifest `flux-instance`): Flux 2.10.0, source-, kustomize-, helm- and notification-controller, images by digest, multi-tenancy lockdown |
| Agents' namespace and identity | Namespace `agents`; ServiceAccount `flux-system/flux-agents`; Role and RoleBinding `agents/flux-agents` with `allowedResources` (manifest `flux-agents`) |
| Sync | GitRepository and Kustomization `flux-system/agents` (manifest `flux-agents-sync`): `ref.branch`, fetched every 1m, sparse checkout of `path` only; the Kustomization applies `path` as `flux-agents`, with prune, every 10m and on every new revision |
| Git credential | Secret `flux-system/flux-git-credentials` (`username: git`, `password`: the token), rendered by sops-nix into `/run/secrets/rendered/flux-git-credentials.yaml` (root, 0400), deployed by k3s (manifest `flux-git-credentials`) |

## What the agents directory may do

The directory is untrusted: a commit there must not reach beyond the
agents. Flux applies it impersonating
`system:serviceaccount:flux-system:flux-agents`, whose only rights are the
Role in `agents`: get, create, patch, delete on `allowedResources`. That
is what kustomize-controller does as this account without `wait` or
health checks (fluxcd/pkg/ssa v0.83.0): GET (`manager_apply.go`,
`manager_diff.go`), server-side apply PATCH (`create` too when the object
is new), GET and DELETE to prune or recreate (`manager_delete.go`); it
never lists or watches. The API server refuses everything else:

- objects in any other namespace, and cluster-scoped kinds (Namespaces,
  ClusterRoles, CRDs, webhooks), including the Namespace `agents` itself
  (its Pod Security labels);
- RBAC, Namespaces, Secrets, ServiceAccounts, Flux's own kinds (sources,
  Kustomizations and HelmReleases with another `serviceAccountName`,
  image automation, `source.extensions.fluxcd.io`), and k3s's HelmCharts
  (`helm.cattle.io`: k3s's helm-controller runs each chart's install job
  as cluster-admin): these may not be listed in `allowedResources` at all,
  evaluation fails;
- pods that break Pod Security `restricted` (the cluster's default, also
  in `agents`).

The GitRepository checks out only `path` (`spec.sparseCheckout`,
source-controller v1.10.1): the clone downloads the whole commit, but the
artifact, and so the kustomize build, holds only `path` and cannot read
other files of the private repository (`hosts/`, `secrets/`), even
through a relative path. `path` must exist in the branch, or the
GitRepository is not Ready.

What remains possible inside the rights: server-side apply forces
ownership, so the directory can take over, change and then prune any
object of an allowed kind in `agents` that it did not create, e.g. the
ConfigMap `kube-root-ca.crt` Kubernetes puts in every namespace (it puts
it back).

The split by directory holds only as far as the repository's own
controls: write access to the private repository also covers `hosts/`
and `flake.nix`, which become root on the hosts (and cluster-admin) at
the next deployment. Protect the branch (review or CODEOWNERS for
everything outside `agents/`) and review what a deployment pins.

A refused object fails the whole revision: the Kustomization turns not
Ready with the API server's message, and the previous revision stays
applied. Every object must name its namespace (`namespace: agents`).

Flux's multi-tenancy lockdown (`cluster.multitenant: true`) is the
operator's profile (`internal/builder/profiles.go`, `profileClusterMultitenant`,
v0.62.1), added to the controllers' arguments:

- `--default-service-account=default` (kustomize-, helm-controller,
  source-watcher): a Flux object that names no service account runs as its
  namespace's `default` account, which has no rights; never as the
  controller itself;
- `--no-cross-namespace-refs=true` (kustomize-, helm-, notification-,
  image-controllers, source-watcher): an object may only reference sources
  and service accounts of its own namespace;
- `--no-remote-bases=true` (kustomize-controller): a kustomization may not
  pull bases from a URL.

The operator's own sync (`spec.sync`) is not used: in multi-tenant mode it
gives its generated `flux-system` Kustomization `serviceAccountName:
kustomize-controller` (same profile), i.e. cluster-admin. Nix declares the
GitRepository and the Kustomization instead, both in `flux-system`, with
`serviceAccountName: flux-agents`; the credential and the service account
stay out of `agents`, where the agents' pods run.

## What runs, and what is ours

Everything in the cluster is upstream: the operator's chart as published
(two values: `image.tag`, the same version pinned by digest, and
`web.enabled = false`), and the Flux distribution the operator renders
from the data in its image, including Flux's NetworkPolicies
(`allow-egress`, `allow-scraping`, `allow-webhooks`) and its namespace
labels (Pod Security `warn: restricted`; the cluster's default enforces
`restricted`, which every Flux and operator pod passes, so `flux-system`
needs no exemption).

Ours is `nix/modules/flux.nix`: the FluxInstance (version, registry,
multi-tenancy), the agents' namespace, service account and Role, the
GitRepository and Kustomization, and the Secret rendered from sops. The
chart and its hash, the operator image digest, and the Flux version are
pinned there; an upgrade is a change of those values and a deployment.

The operator's status web UI is off: upstream serves it without
authentication, with the operator's cluster-admin service account, and
admits port 9080 from every namespace. Turning it on is a deliberate
change of the chart values in `nix/modules/flux.nix` (`web.enabled`, with
authentication per the operator's web UI docs), reached through
`kubectl -n flux-system port-forward svc/flux-operator 9080`.

## The token

A fine-grained personal access token, read-only, for the private
repository only: GitHub, Settings, Developer settings, Personal access
tokens, Fine-grained tokens, Generate new token:

- Resource owner: the owner of the repository; Repository access: Only
  select repositories, the private repository;
- Repository permissions: Contents: Read-only (Metadata: Read-only is
  added); nothing else;
- an expiry you note somewhere: when it expires, Flux stops fetching (the
  GitRepository turns not Ready); what runs stays.

Add it to the cluster-wide sops file (`backfabric keygen` does not
generate it): `sops secrets/common.yaml`, add the line
`flux-git-token: github_pat_...`, save. Check, without printing it:

```sh
sops -d --extract '["flux-git-token"]' secrets/common.yaml | cut -c1-11   # github_pat_
```

The value never enters the Nix store, an argument, or a log: sops-nix
renders the Secret into `/run/secrets/rendered` (a tmpfs) and k3s applies
the file. k3s keeps a copy of every object it applies, with strings cut to
64 characters, in the object's own annotation
`objectset.rio.cattle.io/applied`, so the Secret carries a prefix of the
token in itself: readable by exactly those who can read the Secret, and
encrypted at rest like it.

Replacing the token: change it in `secrets/common.yaml`, commit, deploy.
The deployment restarts k3s (pods keep running): k3s only re-reads a
manifest whose link changed, and the link to the rendered file does not.

Application secrets do not go into the repository: they live in OpenBao
(ADR 0009) and reach the cluster through External Secrets Operator. Flux
has no decryption configured.

## The repository

`path` is a kustomization (or plain manifests) of the private repository,
e.g. `agents/node1/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - hello.yaml
```

```yaml
# agents/node1/hello.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hello
  namespace: agents
data:
  hello: world
```

Every object Flux applies carries the labels
`kustomize.toolkit.fluxcd.io/name: agents` and
`kustomize.toolkit.fluxcd.io/namespace: flux-system`. An object removed
from the directory is deleted from the cluster (prune).

## Status

On the host, as root:

```sh
kubectl -n flux-system get fluxinstance,pods
kubectl -n flux-system get gitrepository,kustomization
kubectl -n flux-system describe kustomization agents   # conditions, inventory
kubectl -n flux-system logs deploy/kustomize-controller
kubectl -n kube-system get helmchart flux-operator
kubectl auth can-i --list -n agents --as=system:serviceaccount:flux-system:flux-agents
```

`fluxinstance/flux` is `READY True` with `Reconciliation finished`;
`gitrepository/agents` shows the fetched revision (`main@sha1:<commit>`),
`kustomization/agents` the applied one.

Fetch and apply now instead of waiting for the interval:

```sh
kubectl -n flux-system annotate --overwrite gitrepository/agents reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl -n flux-system annotate --overwrite kustomization/agents reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

The `flux` CLI (`nix shell nixpkgs#fluxcd`, may be a version behind)
shows the same with `flux get all -A`, and does the above with `flux
reconcile kustomization agents -n flux-system --with-source`.

## Failures

- `gitrepository/agents` not Ready with an authentication error: the
  token expired, was revoked, or lacks access to the repository. Replace
  it (above). Until then nothing new is applied; what runs stays.
- `kustomization/agents` not Ready with `… is forbidden: User
  "system:serviceaccount:flux-system:flux-agents" cannot …`: the
  directory asks for something outside the agents' rights (above). Fix
  the commit; the previous revision stays applied.
- Other messages from `kustomization/agents`: a build error of the
  kustomization, or a rejection by the API server (Pod Security, the
  NodePort/LoadBalancer policy).
- `fluxinstance/flux` missing or `helmchart/flux-operator` failing: the
  chart release failed; `kubectl -n kube-system logs job/helm-install-flux-operator`.
- No pods in `flux-system`: images come from `ghcr.io`; the cluster needs
  registry access.

## Turn off

Turned off, the next deployment removes the k3s manifests: k3s deletes the
Secret, the sync objects, the FluxInstance, the namespace `agents` with
everything in it, and the identity, and uninstalls the operator's release
(its CRDs stay). Delete the FluxInstance first, while the operator still
runs, so that it removes the Flux controllers:

```sh
ssh node1 kubectl -n flux-system delete fluxinstance flux --wait
# then set backfabric.flux.enable = false, commit, deploy
backfabric deploy node1
```

The deployment restarts k3s (its `--disable` list changes). Deploy right
after deleting the FluxInstance: k3s applies every manifest again when it
restarts (and retries a failing one every 15 s), so a k3s restart in
between would bring the FluxInstance back. Afterwards
`kubectl -n kube-system get addon` shows no `flux-*` Addon left.
