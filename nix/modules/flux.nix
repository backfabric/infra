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
#   - everything under that path is untrusted (ADR 0020). The Kustomization
#     impersonates the service account flux-system/flux-agents, whose
#     ClusterRole allows only Namespaces, ServiceAccounts, ConfigMaps,
#     Services, Deployments, Jobs, and CronJobs; the admission policy
#     `backfabric-flux-agents` confines that account to namespaces named
#     `agent-*` and keeps their Pod Security at `restricted`. The
#     controllers run with `--default-service-account=default` (an object
#     without a service account impersonates the `default` account of its
#     namespace, which has no rights, instead of acting as cluster-admin),
#     `--no-cross-namespace-refs`, and (kustomize-controller)
#     `--no-remote-bases`: Flux's multi-tenancy lockdown;
#   - all of it is deployed from the k3s manifests directory; k3s applies
#     the files sorted by name, so the admission policy exists before Flux,
#     and retries a file every 15 seconds until it applies (the sync
#     manifest until Flux's CRDs exist).
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
  # The service account the Kustomization impersonates.
  agents = "flux-agents";
  agentsUser = "system:serviceaccount:${namespace}:${agents}";
  # The admission policy that confines it.
  agentsPolicy = "backfabric-flux-agents";

  # Flux's lockdown flags (fluxcd.io/flux/installation/configuration/
  # multitenancy), appended to the controllers' arguments.
  lockdown = {
    kustomize-controller = [
      "--default-service-account=default"
      "--no-cross-namespace-refs=true"
      "--no-remote-bases=true"
    ];
    helm-controller = [
      "--default-service-account=default"
      "--no-cross-namespace-refs=true"
    ];
  };

  install =
    pkgs.runCommand "flux-install.yaml"
      {
        nativeBuildInputs = [
          pkgs.fluxcd
          pkgs.yq-go
        ];
      }
      ''
        flux install --export \
          --components=source-controller,kustomize-controller,helm-controller \
          >flux-install.yaml
        ${lib.concatStrings (
          lib.mapAttrsToList (deployment: args: ''
            yq -i '(select(.kind == "Deployment" and .metadata.name == "${deployment}")
              | .spec.template.spec.containers[] | select(.name == "manager") | .args)
              += ${builtins.toJSON args}' flux-install.yaml
          '') lockdown
        )}
        # Fail the build if a Deployment was not found.
        ${lib.concatStrings (
          lib.mapAttrsToList (deployment: args: ''
            [[ $(yq 'select(.kind == "Deployment" and .metadata.name == "${deployment}")
              | .spec.template.spec.containers[] | select(.name == "manager") | .args
              | contains(${builtins.toJSON args})' flux-install.yaml) == true ]]
          '') lockdown
        )}
        mv flux-install.yaml $out
      '';

  verbs = [
    "get"
    "list"
    "watch"
    "create"
    "patch"
    "delete"
  ];

  # What the Kustomization may manage: an allowlist. Not allowed, among
  # others: Secrets (workload secrets come from OpenBao, ADR 0009), RBAC
  # objects (they would grant rights), NetworkPolicies (they are additive:
  # one more policy can only allow more traffic), ResourceQuotas and
  # LimitRanges (platform limits), PersistentVolumes and claims, Pods
  # (only through Deployments and Jobs), CRDs and admission webhooks or
  # policies, Endpoints and EndpointSlices (a Service pointing anywhere),
  # and Flux's own kinds (they would sync other sources, with other
  # accounts). Every other cluster-scoped kind is excluded as well.
  agentsRules = [
    {
      apiGroups = [ "" ];
      resources = [
        "namespaces"
        "serviceaccounts"
        "configmaps"
        "services"
      ];
      inherit verbs;
    }
    {
      apiGroups = [ "apps" ];
      resources = [ "deployments" ];
      inherit verbs;
    }
    {
      apiGroups = [ "batch" ];
      resources = [
        "jobs"
        "cronjobs"
      ];
      inherit verbs;
    }
  ];

  # The Pod Security labels that set a level; the version labels and any
  # other key with this prefix are refused.
  psaLevels = map (mode: "pod-security.kubernetes.io/${mode}") [
    "enforce"
    "audit"
    "warn"
  ];
  psaOk = field: ''
    !has(object.metadata.${field}) || object.metadata.${field}.all(k,
      !k.startsWith('pod-security.kubernetes.io/')
      || (k in ${builtins.toJSON psaLevels} && object.metadata.${field}[k] == 'restricted'))'';

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
      # k3s applies them sorted by file name: the admission policy first,
      # then the namespace and the CRDs.
      ${agentsPolicy}.content = [
        {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "ValidatingAdmissionPolicy";
          metadata.name = agentsPolicy;
          spec = {
            failurePolicy = "Fail";
            # Every write of the account, on any resource and subresource
            # (`*/*` covers both); DELETE too, so that pruning stays inside
            # agent-* as well.
            matchConstraints.resourceRules = [
              {
                apiGroups = [ "*" ];
                apiVersions = [ "*" ];
                operations = [
                  "CREATE"
                  "UPDATE"
                  "DELETE"
                ];
                resources = [ "*/*" ];
              }
            ];
            matchConditions = [
              {
                name = "flux-agents";
                expression = "request.userInfo.username == '${agentsUser}'";
              }
            ];
            variables = [
              {
                name = "isNamespace";
                expression = "request.resource.group == '' && request.resource.resource == 'namespaces'";
              }
            ];
            validations = [
              {
                # request.name and request.namespace are set for DELETE as
                # well (object is null then); a cluster-scoped object has no
                # namespace and is refused.
                expression = "variables.isNamespace ? request.name.startsWith('agent-') : request.namespace.startsWith('agent-')";
                message = "The synced directory may only manage namespaces named agent-* and objects in them.";
                reason = "Forbidden";
              }
              {
                expression = "!variables.isNamespace || request.operation == 'DELETE' || ((${psaOk "labels"}) && (${psaOk "annotations"}))";
                message = "pod-security.kubernetes.io/enforce, audit and warn may only be 'restricted'; other pod-security.kubernetes.io/ keys are not allowed.";
                reason = "Forbidden";
              }
            ];
          };
        }
        {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "ValidatingAdmissionPolicyBinding";
          metadata.name = agentsPolicy;
          spec = {
            policyName = agentsPolicy;
            validationActions = [
              "Deny"
              "Audit"
            ];
          };
        }
      ];
      flux-install.source = install;
      # A string, not a Nix path: the rendered file stays out of the store.
      flux-sync-credentials.source = config.sops.templates."flux-sync-credentials.yaml".path;
      flux-sync.content = [
        {
          apiVersion = "v1";
          kind = "ServiceAccount";
          metadata = {
            name = agents;
            inherit namespace;
          };
          # Only impersonated, never used by a pod.
          automountServiceAccountToken = false;
        }
        {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "ClusterRole";
          metadata.name = agents;
          rules = agentsRules;
        }
        {
          apiVersion = "rbac.authorization.k8s.io/v1";
          kind = "ClusterRoleBinding";
          metadata.name = agents;
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            name = agents;
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = agents;
              inherit namespace;
            }
          ];
        }
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
            # Applies and prunes as flux-agents, not as kustomize-controller.
            serviceAccountName = agents;
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
