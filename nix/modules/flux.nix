# Flux (ADR 0027): delivers the agents, and only them, from the private
# repository; Nix delivers the host, k3s and the platform. See
# docs/flux.md.
#
#   - the Flux Operator (controlplaneio-fluxcd), Flux's documented way to
#     install Flux declaratively without `flux bootstrap` writing into the
#     repository: its upstream Helm chart, fetched at build time with a hash
#     and installed by k3s's Helm controller (`autoDeployCharts`), its image
#     pinned by digest in the chart's values, its web UI off;
#   - one FluxInstance, `flux-system/flux`, deployed by k3s: the operator
#     installs Flux at the exact version given (the controller images pinned
#     by digest from the distribution data in the operator's image), with
#     upstream's default components and NetworkPolicies, and Flux's
#     multi-tenancy lockdown (`cluster.multitenant`): the controllers
#     impersonate a service account of the object's namespace (`default`
#     unless the object names one), never use their own cluster-admin
#     identity for a Flux object, refuse cross-namespace references and
#     remote kustomize bases. No `sync`: the operator's sync Kustomization
#     would run as kustomize-controller (cluster-admin);
#   - the agents: the namespace `namespace` (created here, Pod Security
#     `restricted` as every namespace) and, in `flux-system`, a
#     GitRepository and a Kustomization that apply `repository.path` of
#     `repository.url` (prune) as the service account
#     `flux-system/flux-agents`, whose only rights are a Role in
#     `namespace` with `allowedResources`. Everything else a commit asks
#     for (another namespace, cluster-scoped kinds, RBAC, Secrets, Flux's
#     own kinds) is refused by the API server. The source, the credential
#     and the service account stay in `flux-system`, out of reach of what
#     runs in `namespace`;
#   - the Git credential: a GitHub token from sops (`repository.tokenSecret`
#     in the cluster-wide sops file), rendered by sops-nix into a Secret in
#     /run/secrets/rendered and deployed by k3s from there, never in the Nix
#     store, an argument, or a log.
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

  fluxNamespace = "flux-system";
  inherit (cfg) namespace;

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

  # The tenant's objects: its service account, the Secret its
  # GitRepository authenticates with, and the source and Kustomization.
  serviceAccount = "flux-agents";
  credentialsSecret = "flux-git-credentials";
  sync = "agents";

  # Kinds the private repository must never manage, whatever
  # `allowedResources` says: rights (RBAC, service account tokens),
  # credentials, Flux's own kinds (another source or another identity), and
  # wildcards.
  deniedGroups = [
    "*"
    "rbac.authorization.k8s.io"
    "source.toolkit.fluxcd.io"
    "kustomize.toolkit.fluxcd.io"
    "helm.toolkit.fluxcd.io"
    "notification.toolkit.fluxcd.io"
    "fluxcd.controlplane.io"
  ];
  deniedResources = [
    "*"
    "secrets"
    "serviceaccounts"
    "serviceaccounts/token"
  ];
  deniedRules = lib.filter (
    r: lib.elem r.apiGroup deniedGroups || lib.intersectLists r.resources deniedResources != [ ]
  ) cfg.allowedResources;

  # The k3s manifests this module deploys, by name: deployed while it is
  # enabled, and removed (backfabric.k3s.removedManifests) while it is not.
  # k3s retries a file that fails every 15 s, so each waits for what it
  # needs (the operator's CRD, Flux's CRDs, the namespace).
  k3sManifests = {
    flux-instance.content = {
      apiVersion = "fluxcd.controlplane.io/v1";
      kind = "FluxInstance";
      metadata = {
        name = "flux";
        namespace = fluxNamespace;
      };
      spec = {
        distribution = {
          version = fluxVersion;
          registry = "ghcr.io/fluxcd";
        };
        # tenantDefaultServiceAccount stays `default`: a Flux object that
        # names no service account gets the rights of its namespace's
        # `default` account, i.e. none.
        cluster.multitenant = true;
      };
    };

    flux-agents.content = [
      {
        apiVersion = "v1";
        kind = "Namespace";
        metadata.name = namespace;
      }
      {
        apiVersion = "v1";
        kind = "ServiceAccount";
        metadata = {
          name = serviceAccount;
          namespace = fluxNamespace;
        };
        automountServiceAccountToken = false;
      }
      {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        metadata = {
          name = serviceAccount;
          inherit namespace;
        };
        # Server-side apply is a PATCH (that may create), diff and dry-run
        # GET, prune DELETE; no UPDATE.
        rules = map (r: {
          apiGroups = [ r.apiGroup ];
          inherit (r) resources;
          verbs = [
            "get"
            "list"
            "watch"
            "create"
            "patch"
            "delete"
          ];
        }) cfg.allowedResources;
      }
      {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        metadata = {
          name = serviceAccount;
          inherit namespace;
        };
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          name = serviceAccount;
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = serviceAccount;
            namespace = fluxNamespace;
          }
        ];
      }
    ];

    flux-agents-sync.content = [
      {
        apiVersion = "source.toolkit.fluxcd.io/v1";
        kind = "GitRepository";
        metadata = {
          name = sync;
          namespace = fluxNamespace;
        };
        spec = {
          inherit (cfg.repository) url;
          ref.branch = cfg.repository.branch;
          interval = "1m";
          secretRef.name = credentialsSecret;
        };
      }
      {
        apiVersion = "kustomize.toolkit.fluxcd.io/v1";
        kind = "Kustomization";
        metadata = {
          name = sync;
          namespace = fluxNamespace;
        };
        spec = {
          sourceRef = {
            kind = "GitRepository";
            name = sync;
          };
          inherit (cfg.repository) path;
          interval = "10m";
          prune = true;
          serviceAccountName = serviceAccount;
        };
      }
    ];

    flux-git-credentials.source = config.sops.templates."flux-git-credentials.yaml".path;
  };
  operatorChart = "flux-operator";
in
{
  options.backfabric.flux = {
    enable = lib.mkEnableOption "Flux applying the agents from the private repository (docs/flux.md)";

    namespace = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9]([-a-z0-9]*[a-z0-9])?";
      default = "agents";
      description = ''
        The namespace the private repository's agents live in, created by
        this module. Flux applies `repository.path` only into it, with the
        rights of `allowedResources`.
      '';
    };

    allowedResources = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            apiGroup = lib.mkOption {
              type = lib.types.str;
              example = "kagent.dev";
              description = "The API group (`\"\"` for the core group).";
            };
            resources = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              example = [ "agents" ];
              description = "Resource names (plural, lower case) in the group.";
            };
          };
        }
      );
      default = [
        {
          apiGroup = "";
          resources = [ "configmaps" ];
        }
      ];
      description = ''
        What the private repository may manage in `namespace`: the only
        rules of the Role Flux applies `repository.path` with. RBAC, Secrets,
        ServiceAccounts, Flux's own kinds and wildcards are refused at
        evaluation.
      '';
    };

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
        example = "./agents/node1";
        description = ''
          The directory of the repository Flux applies into `namespace`: a
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
      assertions = [
        {
          assertion = deniedRules == [ ];
          message = "backfabric.flux.allowedResources must not contain RBAC, Secrets, ServiceAccounts, Flux's kinds or wildcards: ${builtins.toJSON deniedRules}";
        }
        {
          assertion =
            !lib.elem namespace [
              "default"
              "kube-system"
              "kube-public"
              "kube-node-lease"
              fluxNamespace
            ];
          message = "backfabric.flux.namespace must be a namespace of its own, not ${namespace}";
        }
      ];

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
            namespace = fluxNamespace;
          };
          stringData = {
            username = "git";
            password = config.sops.placeholder.${cfg.repository.tokenSecret};
          };
        };
        restartUnits = [ "k3s.service" ];
      };

      services.k3s = {
        autoDeployCharts.${operatorChart} = {
          name = operatorChart;
          repo = operator.chart;
          inherit (operator) version hash;
          targetNamespace = fluxNamespace;
          createNamespace = true;
          values = {
            image.tag = operator.imageTag;
            # The operator's status web UI: no authentication by default,
            # served with the operator's cluster-admin service account, and
            # the chart's `flux-operator-web` NetworkPolicy admits port 9080
            # from every namespace. Off; the chart then renders neither the
            # policy nor the UI's roles (WEB_SERVER_PORT=0).
            web.enabled = false;
          };
        };
        manifests = k3sManifests;
      };
    })
  ];
}
