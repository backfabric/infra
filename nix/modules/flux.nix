# Flux (GitOps) in the k3s cluster, syncing one directory of the private
# repository (ADR 0020). Nix installs Flux and points it at the repository;
# what is in that directory (the agents' workloads) is managed by Flux, not
# by Nix.
#
#   - the controllers come from `flux install --export` of the nixpkgs
#     `fluxcd` package, run at build time on the manifests embedded in the
#     binary (no network): source-controller, kustomize-controller, and
#     helm-controller (for Helm charts, e.g. External Secrets Operator);
#     no notification or image automation controllers. Flux's network
#     policies are installed as well: ingress to its pods only from
#     flux-system itself (and metrics scraping on 8080);
#   - the controllers meet Pod Security `restricted` (non-root, no privilege
#     escalation, all capabilities dropped, RuntimeDefault seccomp, emptyDir
#     volumes only), so flux-system needs no exemption; their one Service
#     (source-controller's) is ClusterIP;
#   - a GitRepository `fleet` fetches `backfabric.flux.repository.url` over
#     HTTPS every `interval`, authenticated with a read-only fine-grained
#     GitHub token, `flux-git-token` in the cluster-wide sops file
#     (`backfabric.secrets.commonFile`), provided by the operator. The
#     Secret is rendered by sops-nix into /run/secrets/rendered (root,
#     0400), never into the Nix store. `secrets/common.yaml` is readable by
#     every host: before the first agent joins, the token moves to a file
#     only the servers can read (as the k3s token, ADR 0017);
#   - a Kustomization `fleet` applies `repository.path` of that repository
#     and prunes what is removed from it;
#   - all three are deployed from the k3s manifests directory; k3s retries a
#     manifest every 15 seconds until it applies (the sync manifest until
#     Flux's CRDs exist).
#
# On the host, as root: `flux get all`, `kubectl -n flux-system get
# gitrepositories,kustomizations`. See docs/flux.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.backfabric.flux;
  namespace = "flux-system";
  # The GitRepository and the Kustomization.
  name = "fleet";
  credentials = "${name}-git-credentials";

  install = pkgs.runCommand "flux-install.yaml" { nativeBuildInputs = [ pkgs.fluxcd ]; } ''
    flux install --export \
      --components=source-controller,kustomize-controller,helm-controller \
      >$out
  '';

  # Kubernetes durations, as Flux's CRDs validate them.
  duration = lib.types.strMatching "([0-9]+(\\.[0-9]+)?(ms|s|m|h))+";
in
{
  options.backfabric.flux = {
    repository = {
      url = lib.mkOption {
        type = lib.types.strMatching "https://.+";
        example = "https://github.com/example/fleet";
        description = ''
          HTTPS URL of the private repository Flux syncs from. Flux
          authenticates with the GitHub token `flux-git-token` from
          `backfabric.secrets.commonFile`.
        '';
      };
      branch = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "main";
        description = "Branch Flux syncs.";
      };
      path = lib.mkOption {
        type = lib.types.nonEmptyStr;
        example = "./agents";
        description = ''
          Directory of the repository whose manifests Flux applies, relative
          to its root: a `kustomization.yaml`, or plain manifests for which
          Flux generates one. Objects removed from it are deleted from the
          cluster.
        '';
      };
    };
    interval = lib.mkOption {
      type = duration;
      default = "1m";
      description = ''
        How often Flux fetches the branch; a new commit is applied right
        after it is fetched.
      '';
    };
  };

  config = {
    sops.secrets.flux-git-token.sopsFile = config.backfabric.secrets.commonFile;

    sops.templates."flux-sync-credentials.yaml" = {
      # JSON is YAML. The user name `git` with the token as password, as
      # `flux bootstrap github --token-auth` stores it.
      content = builtins.toJSON {
        apiVersion = "v1";
        kind = "Secret";
        metadata = {
          name = credentials;
          inherit namespace;
        };
        type = "Opaque";
        stringData = {
          username = "git";
          password = config.sops.placeholder.flux-git-token;
        };
      };
      # k3s notices changed manifests by the modification time of the link
      # in its manifests directory, which stays the same when sops-nix
      # renders a new token behind it; at start it applies every manifest.
      # The pods keep running (KillMode=process).
      restartUnits = [ "k3s.service" ];
    };

    services.k3s.manifests = {
      # k3s applies them sorted by file name: the namespace and the CRDs
      # come first.
      flux-install.source = install;
      # A string, not a Nix path: the rendered file stays out of the store.
      flux-sync-credentials.source = config.sops.templates."flux-sync-credentials.yaml".path;
      flux-sync.content = [
        {
          apiVersion = "source.toolkit.fluxcd.io/v1";
          kind = "GitRepository";
          metadata = {
            inherit name namespace;
          };
          spec = {
            inherit (cfg.repository) url;
            ref.branch = cfg.repository.branch;
            inherit (cfg) interval;
            secretRef.name = credentials;
          };
        }
        {
          apiVersion = "kustomize.toolkit.fluxcd.io/v1";
          kind = "Kustomization";
          metadata = {
            inherit name namespace;
          };
          spec = {
            sourceRef = {
              kind = "GitRepository";
              inherit name;
            };
            inherit (cfg.repository) path;
            prune = true;
            # Reverts changes made in the cluster; new commits are applied
            # when the GitRepository fetches them.
            interval = "10m";
          };
        }
      ];
    };

    # The CLI of the same version, for `flux get`, `flux reconcile`,
    # `flux logs` on the host.
    environment.systemPackages = [ pkgs.fluxcd ];
  };
}
