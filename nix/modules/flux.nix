# Flux (ADR 0031): GitOps for everything inside the cluster. Nix keeps the
# host, the disks, the network, k3s, and this bootstrap; Flux applies one
# directory of the private repository to the cluster and keeps it there.
# See docs/flux.md.
#
#   - the Flux Operator (controlplaneio-fluxcd), Flux's documented way to
#     install Flux declaratively without `flux bootstrap` writing into the
#     repository: its upstream Helm chart, fetched at build time with a hash
#     and installed by k3s's Helm controller (`autoDeployCharts`), its image
#     pinned by digest in the chart's values;
#   - one FluxInstance, `flux-system/flux`, deployed by k3s: the operator
#     installs Flux at the exact version given (the controller images pinned
#     by digest from the distribution data in the operator's image), with
#     upstream's default components and NetworkPolicies, and generates the
#     GitRepository and the Kustomization (prune) that sync
#     `repository.path` of `repository.url`, both named `flux-system` as
#     `flux bootstrap` names them. The Kustomization applies with the
#     controllers' own identity (cluster-admin): the private repository is
#     trusted as much as the host configuration it holds;
#   - the Git credential: a GitHub token from sops (`repository.tokenSecret`
#     in the cluster-wide sops file), rendered by sops-nix into the Secret
#     `flux-system/flux-system` in /run/secrets/rendered and deployed by k3s
#     from there, never in the Nix store, an argument, or a log.
#
# Off by default; turned off, k3s removes what the manifests applied
# (docs/flux.md, "Turn off", for the order).
{
  config,
  lib,
  ...
}:
let
  cfg = config.backfabric.flux;

  namespace = "flux-system";

  # The operator's chart and image: a chart release and its appVersion.
  # Bumping the version changes the image in the values, so k3s's Helm
  # controller upgrades the release (it compares the HelmChart's spec, not
  # the chart file behind the same URL).
  operator = {
    chart = "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator";
    version = "0.62.1";
    hash = "sha256-GTB1X1CTsljECKKLcCyXkJAoPgCLctQT9ukqSwl6uQg=";
    imageTag = "v0.62.1@sha256:1d09a3f96524d0895fb11e8072d84a3dd029cecdec0f869efa371be6b001469c";
  };

  # An exact Flux version among those the operator's image carries
  # (config/data/flux-images): no automatic upgrades.
  fluxVersion = "2.10.0";

  # The Secret the GitRepository authenticates with, named as `flux
  # bootstrap` names it.
  credentialsSecret = "flux-system";

  # The k3s manifests this module deploys, by name: deployed while it is
  # enabled, and removed (backfabric.k3s.removedManifests) while it is not.
  k3sManifests = {
    flux-instance.content = {
      apiVersion = "fluxcd.controlplane.io/v1";
      kind = "FluxInstance";
      metadata = {
        name = "flux";
        inherit namespace;
      };
      spec = {
        distribution = {
          version = fluxVersion;
          registry = "ghcr.io/fluxcd";
        };
        sync = {
          kind = "GitRepository";
          inherit (cfg.repository) url path;
          ref = "refs/heads/${cfg.repository.branch}";
          pullSecret = credentialsSecret;
        };
      };
    };
    flux-git-credentials.source = config.sops.templates."flux-git-credentials.yaml".path;
  };
  operatorChart = "flux-operator";
in
{
  options.backfabric.flux = {
    enable = lib.mkEnableOption "Flux syncing the cluster from the private repository (docs/flux.md)";

    repository = {
      url = lib.mkOption {
        type = lib.types.strMatching "https://.+";
        example = "https://github.com/example/fleet";
        description = ''
          The HTTPS URL of the private repository Flux syncs from.
        '';
      };

      branch = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "The branch Flux syncs.";
      };

      path = lib.mkOption {
        type = lib.types.str;
        example = "./clusters/node1";
        description = ''
          The directory of the repository Flux applies to the cluster: a
          kustomization or plain manifests. Everything Flux applied from it
          and that is removed from it is deleted (prune).
        '';
      };

      tokenSecret = lib.mkOption {
        type = lib.types.str;
        default = "flux-git-token";
        description = ''
          The name of the secret in `backfabric.secrets.commonFile` with a
          read-only GitHub token for the repository (a fine-grained personal
          access token with Contents: Read-only), which Flux sends as the
          password of the user `git`.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      backfabric.k3s.removedManifests = lib.mkIf (!cfg.enable) (
        lib.attrNames k3sManifests ++ [ operatorChart ]
      );
    }
    (lib.mkIf cfg.enable {
      sops.secrets.${cfg.repository.tokenSecret} = {
        sopsFile = config.backfabric.secrets.commonFile;
      };

      # Root only, in /run/secrets/rendered (a tmpfs). k3s notices a changed
      # manifest by the modification time of the link in its manifests
      # directory (pkg/deploy/controller.go, walkFiles: Lstat), which a new
      # token behind the same link does not change; k3s applies every file
      # when it starts, so a new token restarts it (pods keep running).
      sops.templates."flux-git-credentials.yaml" = {
        content = builtins.toJSON {
          apiVersion = "v1";
          kind = "Secret";
          metadata = {
            name = credentialsSecret;
            inherit namespace;
          };
          stringData = {
            username = "git";
            password = config.sops.placeholder.${cfg.repository.tokenSecret};
          };
        };
        restartUnits = [ "k3s.service" ];
      };

      # The Secret and the FluxInstance wait for the namespace and the CRD
      # the chart's release creates: k3s retries a file that fails every
      # 15 s.
      services.k3s = {
        autoDeployCharts.${operatorChart} = {
          name = operatorChart;
          repo = operator.chart;
          inherit (operator) version hash;
          targetNamespace = namespace;
          createNamespace = true;
          values.image.tag = operator.imageTag;
        };
        manifests = k3sManifests;
      };
    })
  ];
}
