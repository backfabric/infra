# kagent (ADR 0029), installed by its own installer, `kagent install`, run
# by Nix (ADR 0030). See docs/kagent.md.
#
#   - the kagent CLI v1.0.1, the release binary pinned by hash
#     (nix/packages/kagent.nix). The CLI pins what it installs: the charts
#     kagent-crds and kagent 1.0.1, Substrate's (kagent's fork) 1.0.0, and
#     its bundled PostgreSQL by digest;
#   - the k3s manifest `kagent`: the three namespaces the installer uses,
#     created before it with the Pod Security level each needs (the
#     installer sets none, and keeps existing labels): `kagent` and
#     `ate-system` privileged (Substrate's gVisor worker pool and atelet:
#     root, host paths, added capabilities, Unconfined seccomp and
#     AppArmor), `podcertificate-controller-system` baseline (its pod sets
#     no seccomp profile); and static local volumes for the two claims the
#     install makes without a StorageClass (the bundled PostgreSQL's and
#     RustFS's), as the cluster has no provisioner (k3s's local-storage is
#     off);
#   - the oneshot `kagent-install`: waits for the API and the namespaces,
#     and runs `kagent install` unless the cluster already has this
#     install. The stamp of an install (CLI version, flags, values and the
#     API key, hashed together) is kept in the cluster, in the ConfigMap
#     `kagent/backfabric-kagent-install`, so every server sees it and a
#     reinstalled server does not run it again. A Lease
#     (`kagent/backfabric-kagent-install`) makes sure two servers never run
#     it at once. A different stamp runs it again: every chart step is a
#     `helm upgrade --install`, and the installer creates its CAs and
#     Secrets only if they are missing. A failed install writes no stamp
#     and fails the unit; the next start runs it again;
#   - the OpenAI API key from sops (`apiKeySecret` in the cluster-wide sops
#     file). The CLI reads it only from its environment (OPENAI_API_KEY),
#     so it is set for that process alone, never in an argument, the unit's
#     environment, or a log; the CLI hands it to Helm in a 0600 file.
#
# Off by default. Turning it off uninstalls nothing: the teardown is manual
# and ordered (docs/kagent.md, "Turn off").
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.backfabric.kagent;

  kagent = pkgs.callPackage ../packages/kagent.nix { };
  k3s = lib.getExe' config.backfabric.k3s.package "k3s";
  shell = import ../lib/shell.nix;
  kubeconfig = "/etc/rancher/k3s/k3s.yaml";

  namespace = "kagent";
  # The ConfigMap with the stamp and the Lease, both in `namespace`.
  marker = "backfabric-kagent-install";
  # Longer than an install can take: six Helm steps, the PostgreSQL and
  # atelet rollouts, at most 5 min each.
  leaseSeconds = 3600;

  # The model, through the CLI config's values files for the kagent chart
  # (applied after the CLI's own values, before the API key).
  values = pkgs.writeText "kagent-values.json" (
    builtins.toJSON { providers.openAI.model = cfg.model; }
  );
  cliConfig = pkgs.writeText "kagent-config.json" (
    builtins.toJSON { install.kagent.valuesFiles = [ "${values}" ]; }
  );
  installArgs = [
    "--config"
    "${cliConfig}"
    "install"
    "--namespace"
    namespace
    "--provider"
    "OpenAI"
  ];
  # What an install depends on besides the key; the stamp hashes it with
  # the key.
  inputs = builtins.hashString "sha256" (
    builtins.toJSON {
      inherit (kagent) version;
      args = installArgs;
      inherit (cfg) model;
    }
  );

  # Claims the installer makes without a StorageClass, each bound to a
  # local volume on `dataNode` by name.
  volumes = {
    postgresql = {
      claimNamespace = namespace;
      claim = "kagent-postgresql";
      size = "500Mi";
      # The bundled PostgreSQL's fsGroup (postgres in postgres:18-alpine).
      uid = 70;
    };
    rustfs = {
      claimNamespace = "ate-system";
      claim = "rustfs-data";
      size = "1Gi";
      # RustFS's runAsUser and fsGroup in the substrate chart.
      uid = 10001;
    };
  };
  dataDir = name: "/var/lib/kagent/${name}";

  manifest = [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata = {
        name = namespace;
        labels."pod-security.kubernetes.io/enforce" = "privileged";
      };
    }
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata = {
        name = "ate-system";
        labels."pod-security.kubernetes.io/enforce" = "privileged";
      };
    }
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata = {
        name = "podcertificate-controller-system";
        labels = {
          "pod-security.kubernetes.io/enforce" = "baseline";
          "pod-security.kubernetes.io/warn" = "restricted";
        };
      };
    }
  ]
  ++ lib.mapAttrsToList (name: v: {
    apiVersion = "v1";
    kind = "PersistentVolume";
    metadata.name = "kagent-${name}";
    spec = {
      capacity.storage = v.size;
      accessModes = [ "ReadWriteOnce" ];
      volumeMode = "Filesystem";
      # The claims name no class, and the cluster has no default one.
      storageClassName = "";
      # The data stays when the claim or the volume goes.
      persistentVolumeReclaimPolicy = "Retain";
      claimRef = {
        namespace = v.claimNamespace;
        name = v.claim;
      };
      local.path = dataDir name;
      nodeAffinity.required.nodeSelectorTerms = [
        {
          matchExpressions = [
            {
              key = "kubernetes.io/hostname";
              operator = "In";
              # k3s names the node after the host.
              values = [ cfg.dataNode ];
            }
          ];
        }
      ];
    };
  }) volumes;

  # The k3s manifests this module deploys, by name.
  k3sManifests = {
    kagent.content = manifest;
  };

  install = pkgs.writeShellApplication {
    name = "kagent-install";
    runtimeInputs = [
      kagent
      pkgs.kubernetes-helm
      # kubectl, a link to k3s: `kagent install` runs both from PATH.
      config.backfabric.k3s.package
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      export KUBECONFIG=${kubeconfig}
      # Helm's cache and configuration, and kubectl's, in the unit's
      # runtime directory: removed when it stops.
      export HOME=$RUNTIME_DIRECTORY
      export HELM_CACHE_HOME=$HOME/helm/cache HELM_CONFIG_HOME=$HOME/helm/config HELM_DATA_HOME=$HOME/helm/data
      key=$CREDENTIALS_DIRECTORY/openai-api-key
      host=${lib.escapeShellArg config.networking.hostName}

      ${shell.waitUntil}
      ${shell.apiReady k3s}
      # The namespaces of the k3s manifest `kagent`, with their labels.
      labelled() {
        [[ $(kubectl get namespace "$1" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null) == "$2" ]]
      }
      wait_until 300 "the k3s API with $KUBECONFIG; is k3s running? systemctl status k3s" api_ready
      for ns in ${namespace}:privileged ate-system:privileged podcertificate-controller-system:baseline; do
        wait_until 300 "the namespace ''${ns%:*}; journalctl -u k3s | grep kagent" labelled "''${ns%:*}" "''${ns#*:}"
      done

      # The stamp: the install's inputs and the key, hashed together.
      stamp=$({ echo ${inputs}; cat "$key"; } | sha256sum | cut -d' ' -f1)

      # Installed with this stamp, and kagent's release is deployed (`kagent
      # uninstall` keeps the namespace, and so the stamp).
      up_to_date() {
        [[ $(kubectl -n ${namespace} get configmap ${marker} -o jsonpath='{.data.stamp}' 2>/dev/null) == "$stamp" ]] &&
          [[ $(helm status kagent -n ${namespace} -o json 2>/dev/null | jq -r .info.status) == deployed ]]
      }
      if up_to_date; then
        echo "kagent is up to date (kagent ${kagent.version}, stamp ''${stamp:0:12})."
        exit 0
      fi

      # The Lease: created by one server at a time; taken over only from
      # this host (a run that was killed) or once it expired.
      lease() {
        local now
        now=$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)
        jq -n --arg holder "$host" --arg now "$now" --arg version "''${1-}" '{
          apiVersion: "coordination.k8s.io/v1", kind: "Lease",
          metadata: ({name: "${marker}", namespace: "${namespace}"}
            + if $version == "" then {} else {resourceVersion: $version} end),
          spec: {holderIdentity: $holder, leaseDurationSeconds: ${toString leaseSeconds},
            acquireTime: $now, renewTime: $now}
        }'
      }
      acquire() {
        local current
        lease | kubectl create -f - >/dev/null 2>&1 && return 0
        current=$(kubectl -n ${namespace} get lease ${marker} -o json 2>/dev/null) || return 1
        jq -e --arg holder "$host" '.spec.holderIdentity == $holder
          or (.spec.renewTime | sub("\\.[0-9]+"; "") | fromdateiso8601) + .spec.leaseDurationSeconds < now' \
          <<<"$current" >/dev/null || return 1
        # A replace with the read resourceVersion: of two servers taking
        # over at once, one gets a conflict.
        lease "$(jq -r .metadata.resourceVersion <<<"$current")" | kubectl replace -f - >/dev/null 2>&1
      }
      release() {
        [[ $(kubectl -n ${namespace} get lease ${marker} -o jsonpath='{.spec.holderIdentity}' 2>/dev/null) == "$host" ]] &&
          kubectl -n ${namespace} delete lease ${marker} >/dev/null
        return 0
      }
      wait_until ${toString leaseSeconds} "the Lease ${namespace}/${marker}, held by another server; kubectl -n ${namespace} get lease ${marker} -o yaml" acquire
      trap release EXIT

      # Another server may have installed it meanwhile.
      if up_to_date; then
        echo "kagent is up to date (kagent ${kagent.version}, stamp ''${stamp:0:12})."
        exit 0
      fi

      echo "Running kagent install (kagent ${kagent.version}, stamp ''${stamp:0:12})."
      # The key only in the environment of `kagent install` (and the helm
      # and kubectl it runs), never in an argument.
      OPENAI_API_KEY=$(<"$key") kagent ${lib.escapeShellArgs installArgs}

      kubectl -n ${namespace} create configmap ${marker} \
        --from-literal=stamp="$stamp" --from-literal=version=${kagent.version} \
        --dry-run=client -o json |
        kubectl apply --server-side --force-conflicts --field-manager=kagent-install -f - >/dev/null
      echo "kagent installed (stamp ''${stamp:0:12})."
    '';
  };
in
{
  options.backfabric.kagent = {
    enable = lib.mkEnableOption "kagent, installed by `kagent install` (docs/kagent.md)";

    model = lib.mkOption {
      type = lib.types.str;
      default = "gpt-5-mini";
      description = ''
        The OpenAI model of kagent's default ModelConfig
        (`kagent/default-model-config`), the one `kagent install` picks
        by default. A change runs `kagent install` again.
      '';
    };

    apiKeySecret = lib.mkOption {
      type = lib.types.str;
      default = "kagent-openai-api-key";
      description = ''
        The name of the secret in `backfabric.secrets.commonFile` with the
        OpenAI API key. Every server reads it: any of them may run the
        install. A change of the key runs `kagent install` again.
      '';
    };

    dataNode = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = ''
        The node (k3s names nodes after their hosts) whose local disk holds
        the bundled PostgreSQL's and RustFS's volumes, in
        /var/lib/kagent; both pods run there. Every server of the cluster
        must set the same value: each deploys the same manifest.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # PodCertificateRequest and ClusterTrustBundle, which Substrate's
        # mTLS needs, are served at certificates.k8s.io/v1 from 1.37.
        assertion = lib.versionAtLeast config.backfabric.k3s.package.version "1.37";
        message = "backfabric.kagent needs Kubernetes 1.37 or later: set backfabric.k3s.package (now ${config.backfabric.k3s.package.version})";
      }
    ];

    sops.secrets.${cfg.apiKeySecret} = {
      sopsFile = config.backfabric.secrets.commonFile;
    };

    # For the operator: `kagent uninstall` (docs/kagent.md, "Turn off"),
    # `kagent version`.
    environment.systemPackages = [ kagent ];

    services.k3s.manifests = k3sManifests;

    systemd.tmpfiles.settings."10-backfabric-kagent" =
      lib.mkIf (cfg.dataNode == config.networking.hostName)
        (
          lib.mapAttrs' (
            name: v:
            lib.nameValuePair (dataDir name) {
              d = {
                mode = "0700";
                user = toString v.uid;
                group = toString v.uid;
              };
            }
          ) volumes
        );

    # No Restart=: waits for what it needs for a bounded time and then
    # fails, so that a deployment reports it. Runs at boot and at every
    # deployment; does nothing when the cluster has this install.
    systemd.services.kagent-install = {
      description = "Install kagent with kagent install, unless the cluster has this install";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe install;
        # Waiting for another server's install, then its own.
        TimeoutStartSec = "2h";
        LoadCredential = "openai-api-key:${config.sops.secrets.${cfg.apiKeySecret}.path}";
        RuntimeDirectory = "kagent-install";
        RuntimeDirectoryMode = "0700";
        PrivateTmp = true;
        UMask = "0077";
      };
    };
  };
}
