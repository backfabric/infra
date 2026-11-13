# The platform's PostgreSQL (ADR 0025): one CloudNativePG Cluster,
# `platform` in the namespace `postgres`, for platform services. See
# docs/postgres.md.
#
#   - the operator from CloudNativePG's release manifest, with its image
#     pinned by digest when the manifest is built (the build fails if an
#     image reference is left without one), deployed by k3s. The manifest's
#     CRDs are too large for client-side `kubectl apply` (upstream asks for
#     `--server-side`): kubectl stores the whole object in an annotation,
#     over the 256 KiB limit. k3s's deploy controller (wrangler's apply)
#     stores a gzipped copy with strings cut to 64 bytes, about 28 KB for
#     the largest (clusters), so k3s applies them as they are;
#   - one instance, PostgreSQL from CloudNativePG's minimal image (pinned by
#     digest), on a static `local` PersistentVolume in
#     /var/lib/postgres-platform bound to the instance's claim by name, as
#     Substrate's volumes. No StorageClass object exists and no provisioner
#     serves the class name;
#   - CloudNativePG's defaults: TLS with its own CA, which it renews; pods
#     that pass Pod Security `restricted`. Superuser access over the network
#     off (`enableSuperuserAccess: false`);
#   - `databases`: each a Database owned by a managed role (in the
#     Cluster, not a DatabaseRole: no finalizer that can hold the namespace
#     when the subsystem is turned off) with a random password.
#     `postgres-credentials` generates the password into a Secret in
#     `postgres` (CloudNativePG sets it), and copies what the service needs
#     (host, port, database, user, password, CA) into the Secret
#     `postgres-<database>` of the service's namespace; at every deployment
#     and daily (the CA is renewed every 83 days);
#   - pg_hba: each owner only to its database, over TLS, with a password;
#     every other network login is rejected;
#   - ingress to the namespace is denied, except from the operator and, to
#     5432, from the namespaces of `databases`; ingress to the operator's
#     namespace only to its webhook;
#   - no backups yet (docs/postgres.md).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.backfabric.postgres;

  operatorManifest = pkgs.callPackage ../packages/cloudnative-pg.nix { };
  inherit (operatorManifest) postgresImage;

  namespace = "postgres";
  operatorNamespace = "cnpg-system";
  cluster = "platform";
  # CloudNativePG names an instance's claim after the instance: the first
  # is `<cluster>-1`.
  claim = "${cluster}-1";
  # A class name only this volume and its claim use.
  storageClass = "postgres-platform-local";
  dataDir = "/var/lib/postgres-platform";
  # The postgres user of CloudNativePG's images (the pods' runAsUser and
  # fsGroup).
  uid = 26;
  host = "${cluster}-rw.${namespace}.svc";
  kubeconfig = "/etc/rancher/k3s/k3s.yaml";

  owners = lib.unique (map (d: d.owner) cfg.databases);
  clientNamespaces = lib.unique (map (d: d.namespace) cfg.databases);
  # The Secret CloudNativePG reads a role's password from (`_` as `-`).
  roleSecret = owner: "postgres-role-${lib.replaceStrings [ "_" ] [ "-" ] owner}";
  # A PostgreSQL identifier that needs no quoting, and with `_` as `-` a
  # Kubernetes object name.
  identifier = lib.types.strMatching "[a-z]([a-z0-9_]{0,61}[a-z0-9])?";

  clusterManifest = [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = namespace;
    }
    {
      apiVersion = "v1";
      kind = "PersistentVolume";
      metadata.name = "postgres-${cluster}";
      spec = {
        capacity.storage = cfg.storageSize;
        accessModes = [ "ReadWriteOnce" ];
        volumeMode = "Filesystem";
        storageClassName = storageClass;
        # The data stays when the claim or the volume goes.
        persistentVolumeReclaimPolicy = "Retain";
        claimRef = {
          inherit namespace;
          name = claim;
        };
        local.path = dataDir;
        nodeAffinity.required.nodeSelectorTerms = [
          {
            matchExpressions = [
              {
                key = "kubernetes.io/hostname";
                operator = "In";
                # k3s names the node after the host.
                values = [ config.networking.hostName ];
              }
            ];
          }
        ];
      };
    }
    {
      apiVersion = "postgresql.cnpg.io/v1";
      kind = "Cluster";
      metadata = {
        name = cluster;
        inherit namespace;
      };
      spec = {
        instances = 1;
        imageName = postgresImage;
        enableSuperuserAccess = false;
        storage = {
          inherit storageClass;
          size = cfg.storageSize;
          # The claim is bound to a static volume: no StorageClass, nothing
          # that could grow it. A patched claim would be rejected and stop
          # every later reconciliation of the Cluster.
          resizeInUseVolumes = false;
        };
        # CloudNativePG puts these after its own rules (local peer logins,
        # replication by certificate) and before its catch-all `host all
        # all all scram-sha-256`, which the last line shadows.
        postgresql.pg_hba = map (d: "hostssl ${d.name} ${d.owner} all scram-sha-256") cfg.databases ++ [
          "host all all all reject"
        ];
        managed.roles = map (owner: {
          name = owner;
          ensure = "present";
          login = true;
          passwordSecret.name = roleSecret owner;
        }) owners;
      };
    }
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "NetworkPolicy";
      metadata = {
        name = "default-deny-ingress";
        inherit namespace;
      };
      spec = {
        podSelector = { };
        policyTypes = [ "Ingress" ];
      };
    }
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "NetworkPolicy";
      metadata = {
        name = "${cluster}-ingress";
        inherit namespace;
      };
      spec = {
        podSelector.matchLabels."cnpg.io/cluster" = cluster;
        policyTypes = [ "Ingress" ];
        ingress = [
          # The operator: the instance manager's status endpoint, and
          # PostgreSQL.
          {
            from = [
              {
                namespaceSelector.matchLabels."kubernetes.io/metadata.name" = operatorNamespace;
                podSelector.matchLabels."app.kubernetes.io/name" = "cloudnative-pg";
              }
            ];
            ports = [
              {
                protocol = "TCP";
                port = 8000;
              }
              {
                protocol = "TCP";
                port = 5432;
              }
            ];
          }
        ]
        ++ lib.optional (clientNamespaces != [ ]) {
          from = [
            {
              namespaceSelector.matchExpressions = [
                {
                  key = "kubernetes.io/metadata.name";
                  operator = "In";
                  values = clientNamespaces;
                }
              ];
            }
          ];
          ports = [
            {
              protocol = "TCP";
              port = 5432;
            }
          ];
        };
      };
    }
    # The operator's namespace: only its webhook, which the API server
    # calls (from any address: the API server runs on the host). Its
    # metrics (8080) stay closed.
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "NetworkPolicy";
      metadata = {
        name = "webhook-only";
        namespace = operatorNamespace;
      };
      spec = {
        podSelector = { };
        policyTypes = [ "Ingress" ];
        ingress = [
          {
            ports = [
              {
                protocol = "TCP";
                port = 9443;
              }
            ];
          }
        ];
      };
    }
  ]
  ++ map (d: {
    apiVersion = "postgresql.cnpg.io/v1";
    kind = "Database";
    metadata = {
      name = "${cluster}-${lib.replaceStrings [ "_" ] [ "-" ] d.name}";
      inherit namespace;
    };
    spec = {
      cluster.name = cluster;
      inherit (d) name owner;
      ensure = "present";
      # The default, pinned: removing the entry keeps the database.
      databaseReclaimPolicy = "retain";
    };
  }) cfg.databases;

  # The k3s manifests this module deploys, by name: deployed while it is
  # enabled, and removed (backfabric.k3s.removedManifests) while it is not.
  # k3s applies them in the order of their file names: the operator (and
  # its CRDs) first; the Cluster is retried until its webhook answers.
  k3sManifests = {
    postgres-operator.source = operatorManifest;
    postgres.content = clusterManifest;
  };

  k3s = lib.getExe' config.backfabric.k3s.package "k3s";
  shell = import ../lib/shell.nix;

  credentials = pkgs.writeShellApplication {
    name = "postgres-credentials";
    runtimeInputs = [
      pkgs.jq
      pkgs.openssl
      pkgs.coreutils
    ];
    text = ''
      export KUBECONFIG=${kubeconfig}
      kubectl() { ${k3s} kubectl "$@"; }

      ${shell.waitUntil}
      ${shell.apiReady k3s}
      exists() { kubectl get "$@" >/dev/null 2>&1; }

      wait_until 300 "the k3s API with $KUBECONFIG; is k3s running? systemctl status k3s" api_ready
      wait_until 300 "the namespace ${namespace}; journalctl -u k3s | grep postgres" exists namespace ${namespace}

      # A role's password is generated once, into the Secret CloudNativePG
      # reads (labelled, so that it applies changes), and never in an
      # argument (process listings) or a file.
      owners=(${lib.escapeShellArgs owners})
      for owner in "''${owners[@]}"; do
        secret=postgres-role-''${owner//_/-}
        exists -n ${namespace} secret "$secret" && continue
        PASSWORD=$(openssl rand -hex 32) OWNER=$owner SECRET=$secret jq -n '{
          apiVersion: "v1", kind: "Secret", type: "kubernetes.io/basic-auth",
          metadata: {name: env.SECRET, namespace: "${namespace}", labels: {"cnpg.io/reload": "true"}},
          stringData: {username: env.OWNER, password: env.PASSWORD}
        }' | kubectl create -f -
      done

      # The cluster's CA, created by the operator.
      ca() { kubectl -n ${namespace} get secret ${cluster}-ca -o json 2>/dev/null | jq -er '.data."ca.crt"'; }
      wait_until 600 "the Secret ${namespace}/${cluster}-ca; kubectl -n ${namespace} describe cluster ${cluster}" ca >/dev/null

      # What a service needs, in its namespace (created if missing).
      jq -r '.[] | "\(.name) \(.owner) \(.namespace)"' <<<${lib.escapeShellArg (builtins.toJSON cfg.databases)} |
        while read -r name owner client; do
          exists namespace "$client" || kubectl create namespace "$client"
          kubectl -n ${namespace} get secret "postgres-role-''${owner//_/-}" -o json |
            CA=$(ca) NAME=$name CLIENT=$client jq '{
              apiVersion: "v1", kind: "Secret",
              metadata: {name: "postgres-\(env.NAME | gsub("_"; "-"))", namespace: env.CLIENT},
              data: {
                host: ("${host}" | @base64), port: ("5432" | @base64),
                dbname: (env.NAME | @base64), username: .data.username,
                password: .data.password, "ca.crt": env.CA
              }
            }' | kubectl apply --server-side --field-manager=postgres-credentials -f -
        done
    '';
  };
in
{
  options.backfabric.postgres = {
    enable = lib.mkEnableOption "the platform PostgreSQL, CloudNativePG's Cluster `platform` in the namespace `postgres` (docs/postgres.md)";

    storageSize = lib.mkOption {
      type = lib.types.strMatching "[0-9]+(Mi|Gi|Ti)";
      default = "20Gi";
      description = ''
        The size of the instance's volume (the PersistentVolume and the
        Cluster's claim). Fixed once the claim exists: CloudNativePG does
        not resize it. Not enforced either: the volume is a directory in
        ${dataDir} on the host's file system, which it shares.
      '';
    };

    databases = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = identifier;
              description = "The database's name.";
            };
            owner = lib.mkOption {
              type = identifier;
              description = "The role that owns it and that the service logs in as.";
            };
            namespace = lib.mkOption {
              type = lib.types.strMatching "[a-z0-9]([-a-z0-9]*[a-z0-9])?";
              description = ''
                The namespace of the service that uses it: its pods may
                connect to PostgreSQL, and the Secret
                `postgres-<name>` (`_` as `-`) there has the connection's
                host, port, dbname, username, password and ca.crt.
              '';
            };
          };
        }
      );
      default = [ ];
      example = [
        {
          name = "a2a";
          owner = "a2a";
          namespace = "a2a";
        }
      ];
      description = ''
        The databases of the platform services. Removing an entry keeps the
        database, its role and the Secrets (docs/postgres.md).
      '';
    };
  };

  # Disabled: k3s removes what the manifests applied (docs/postgres.md,
  # "Turning it off", lists what stays).
  config = lib.mkMerge [
    { backfabric.k3s.removedManifests = lib.mkIf (!cfg.enable) (lib.attrNames k3sManifests); }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = lib.length (lib.unique (map (d: d.name) cfg.databases)) == lib.length cfg.databases;
          message = "backfabric.postgres.databases has duplicate names";
        }
        {
          assertion = !lib.elem namespace clientNamespaces;
          message = "backfabric.postgres.databases: a service's namespace must not be ${namespace}";
        }
      ];

      services.k3s.manifests = k3sManifests;

      systemd.tmpfiles.settings."10-backfabric-postgres".${dataDir}.d = {
        mode = "0700";
        user = toString uid;
        group = toString uid;
      };

      # No Restart=: waits for what it needs for a bounded time and then
      # fails, so that a deployment reports it. Runs at every deployment
      # (as otel-jwks), at boot, and daily, for the renewed CA.
      systemd.services.postgres-credentials = {
        description = "Generate the platform PostgreSQL's role passwords and copy them to the services";
        wantedBy = [ "multi-user.target" ];
        after = [ "k3s.service" ];
        startAt = "daily";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe credentials;
          TimeoutStartSec = "20min";
        };
      };
      systemd.timers.postgres-credentials.timerConfig.Persistent = true;
    })
  ];
}
