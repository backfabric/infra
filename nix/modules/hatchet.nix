# Hatchet as the platform's task queue (ADR 0027): the engine (gRPC for
# workers and clients), the API and the dashboard in the namespace
# `hatchet`, on the platform PostgreSQL (ADR 0025). See docs/hatchet.md.
#
#   - Hatchet's release images, pinned by digest; hand-written objects
#     instead of the Helm chart (ADR 0027), rendered into one manifest whose
#     build fails if an image reference is left without a digest. Every pod
#     passes Pod Security `restricted` (non-root, no capabilities,
#     RuntimeDefault seccomp, read-only root file system);
#   - the database `hatchet` from `backfabric.postgres.databases`;
#     DATABASE_URL from its Secret, TLS verify-full against its CA. The
#     engine and the API run `hatchet-migrate` first (goose, under a
#     session lock, so both may run at once); it retries its first
#     connection for 30 seconds (kube-router admits a new pod's address
#     with a delay);
#   - the message queue in PostgreSQL (`SERVER_MSGQUEUE_KIND=postgres`), no
#     RabbitMQ; gRPC without TLS inside the cluster;
#   - NetworkPolicy: all ingress and egress of the namespace denied except
#     DNS, PostgreSQL, the engine's gRPC from the API and from
#     `clientNamespaces`, the API from the dashboard, and the Kubernetes API
#     from the setup Jobs. Nothing else reaches the API or the dashboard:
#     `kubectl port-forward` (docs/hatchet.md);
#   - sign-up, invites and new tenants off. `hatchet-credentials` (on the
#     host) generates the dashboard admin's password, runs the setup Jobs
#     that generate the encryption keys (`hatchet-admin k8s quickstart`) and
#     one client token per client namespace (`hatchet-admin k8s
#     create-worker-token`), each once, copies each token into the Secret
#     `hatchet-client-token` of its namespace, and deletes the token Secrets
#     of namespaces no longer listed.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.backfabric.hatchet;

  # Upgrade: the version and the digests (`crane digest <ref>`: the
  # multi-platform index), together.
  version = "v0.114.2";
  images =
    lib.mapAttrs (name: digest: "ghcr.io/hatchet-dev/hatchet/hatchet-${name}:${version}@${digest}")
      {
        engine = "sha256:247120b5fabb0085784d3adcf4aebfaca670a400c950d7f53d7ea95c858b4f21";
        api = "sha256:36070cebd529f4759bb23bc6cf298aaa02242358426fc6bd4880c157b47c1238";
        frontend = "sha256:41cdce28471bdd48e2549db4d93495421e3ff49e102592a988d64f865603ac4d";
        migrate = "sha256:fee74780773f7e76c4d090437a1cbdebad12a5ae90a5705ffad4e306d69b70d8";
        admin = "sha256:e5d8fd721d196d51cb631871d11d120b06fd3a4f29fa063c06955d8ec8930873";
      };

  namespace = "hatchet";
  grpcPort = 7070;
  apiPort = 8080;
  engineAddress = "hatchet-engine.${namespace}.svc:${toString grpcPort}";
  # The token Secret in the namespace `hatchet`, per client namespace.
  tokenSecret = ns: "hatchet-token-${ns}";
  kubeconfig = "/etc/rancher/k3s/k3s.yaml";
  # Marks the token Secrets hatchet-credentials manages, with the client
  # namespace as the value.
  clientLabel = "backfabric.io/hatchet-client";

  # Configuration shared by every Hatchet process; the secrets come from
  # the Secrets `hatchet-keys` and `postgres-hatchet`.
  env = [
    # Expanded by the kubelet from the variables before it; the password is
    # hex (postgres-credentials). `timezone`: Hatchet refuses to start on a
    # session that is not UTC.
    (secretEnv "DB_HOST" "host")
    (secretEnv "DB_PORT" "port")
    (secretEnv "DB_NAME" "dbname")
    (secretEnv "DB_USER" "username")
    (secretEnv "DB_PASSWORD" "password")
    {
      name = "DATABASE_URL";
      value = "postgresql://$(DB_USER):$(DB_PASSWORD)@$(DB_HOST):$(DB_PORT)/$(DB_NAME)?sslmode=verify-full&sslrootcert=/run/postgres/ca.crt&timezone=UTC";
    }
  ]
  ++ lib.mapAttrsToList (name: value: { inherit name value; }) {
    SERVER_MSGQUEUE_KIND = "postgres";
    SERVER_GRPC_BIND_ADDRESS = "0.0.0.0";
    SERVER_GRPC_PORT = toString grpcPort;
    SERVER_GRPC_BROADCAST_ADDRESS = engineAddress;
    SERVER_GRPC_INSECURE = "t";
    # The dashboard through `kubectl port-forward` to localhost:8080. The
    # cookie domain is the Helm chart's for that case: with a port it is not
    # a valid domain, Go drops the attribute, and the cookie is host-only.
    SERVER_URL = "http://localhost:8080";
    SERVER_AUTH_COOKIE_DOMAIN = "localhost:8080";
    SERVER_AUTH_COOKIE_INSECURE = "t";
    SERVER_ALLOW_SIGNUP = "f";
    SERVER_ALLOW_INVITES = "f";
    SERVER_ALLOW_CREATE_TENANT = "f";
    # A request to security.hatchet.run at startup: no egress for it.
    SERVER_SECURITY_CHECK_ENABLED = "f";
  };
  secretEnv = name: key: {
    inherit name;
    valueFrom.secretKeyRef = {
      name = "postgres-hatchet";
      inherit key;
    };
  };

  # Pod Security `restricted`, with a read-only root file system.
  restricted = {
    allowPrivilegeEscalation = false;
    readOnlyRootFilesystem = true;
    capabilities.drop = [ "ALL" ];
  };
  container =
    name: image: extra:
    {
      inherit name image env;
      envFrom = [ { secretRef.name = "hatchet-keys"; } ];
      volumeMounts = [
        {
          name = "postgres";
          mountPath = "/run/postgres";
          readOnly = true;
        }
      ];
      securityContext = restricted;
    }
    // extra;
  migrate = container "migrate" images.migrate {
    command = [ "/hatchet/hatchet-migrate" ];
    envFrom = [ ];
  };

  podSpec = name: spec: {
    metadata.labels."app.kubernetes.io/name" = name;
    spec = {
      automountServiceAccountToken = false;
      securityContext = {
        runAsNonRoot = true;
        runAsUser = 65532;
        runAsGroup = 65532;
        seccompProfile.type = "RuntimeDefault";
      };
      volumes = [
        {
          name = "postgres";
          secret = {
            secretName = "postgres-hatchet";
            items = [
              {
                key = "ca.crt";
                path = "ca.crt";
              }
            ];
          };
        }
      ];
    }
    // spec;
  };

  deployment = name: spec: [
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        inherit name namespace;
      };
      spec = {
        replicas = 1;
        selector.matchLabels."app.kubernetes.io/name" = name;
        template = podSpec name spec;
      };
    }
  ];

  service = name: port: {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      inherit name namespace;
    };
    spec = {
      selector."app.kubernetes.io/name" = name;
      ports = [
        {
          inherit port;
          targetPort = port;
        }
      ];
    };
  };

  httpProbe = path: port: {
    httpGet = {
      inherit path port;
    };
    periodSeconds = 5;
  };

  pods = app: { podSelector.matchLabels."app.kubernetes.io/name" = app; };
  networkPolicy = name: spec: {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = {
      inherit name namespace;
    };
    inherit spec;
  };
  # Lets the pods `app` send (Egress) or receive (Ingress) TCP to `port`
  # to or from `peers`.
  allow =
    app: direction: peers: port:
    networkPolicy "${app}-${lib.toLower direction}-${toString port}" {
      inherit (pods app) podSelector;
      policyTypes = [ direction ];
      ${lib.toLower direction} = [
        {
          ${if direction == "Ingress" then "from" else "to"} = peers;
          ports = [
            {
              protocol = "TCP";
              inherit port;
            }
          ];
        }
      ];
    };

  objects = [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = namespace;
    }
  ]
  ++ deployment "hatchet-engine" {
    initContainers = [ migrate ];
    containers = [
      (container "engine" images.engine {
        command = [ "/hatchet/hatchet-engine" ];
        ports = [ { containerPort = grpcPort; } ];
        readinessProbe = httpProbe "/ready" 8733;
        livenessProbe = httpProbe "/live" 8733 // {
          initialDelaySeconds = 60;
        };
      })
    ];
  }
  ++ deployment "hatchet-api" {
    initContainers = [
      migrate
      # The admin and the default tenant, if missing.
      (container "seed" images.admin {
        command = [
          "/hatchet/hatchet-admin"
          "seed"
        ];
        envFrom = [ { secretRef.name = "hatchet-admin"; } ];
      })
    ];
    containers = [
      (container "api" images.api {
        command = [ "/hatchet/hatchet-api" ];
        ports = [ { containerPort = apiPort; } ];
        readinessProbe = httpProbe "/api/ready" apiPort;
        livenessProbe = httpProbe "/api/live" apiPort // {
          initialDelaySeconds = 60;
        };
      })
    ];
  }
  ++ deployment "hatchet-frontend" {
    containers = [
      {
        name = "frontend";
        image = images.frontend;
        command = [
          "/app/hatchet-staticfileserver"
          "-static-asset-dir=/app/dist"
          "-port=${toString apiPort}"
          "-api-proxy=http://hatchet-api.${namespace}.svc:${toString apiPort}"
        ];
        ports = [ { containerPort = apiPort; } ];
        readinessProbe = httpProbe "/" apiPort;
        securityContext = restricted;
      }
    ];
    volumes = [ ];
  }
  ++ [
    (service "hatchet-engine" grpcPort)
    (service "hatchet-api" apiPort)
    (service "hatchet-frontend" apiPort)

    # The setup Jobs of hatchet-credentials: write the keys and the tokens,
    # and nothing else.
    {
      apiVersion = "v1";
      kind = "ServiceAccount";
      metadata = {
        name = "hatchet-setup";
        inherit namespace;
      };
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "Role";
      metadata = {
        name = "hatchet-setup";
        inherit namespace;
      };
      rules = [
        {
          apiGroups = [ "" ];
          resources = [ "secrets" ];
          verbs = [ "create" ];
        }
        {
          apiGroups = [ "" ];
          resources = [ "secrets" ];
          resourceNames = [ "hatchet-keys" ] ++ map tokenSecret cfg.clientNamespaces;
          verbs = [
            "get"
            "update"
          ];
        }
      ];
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "RoleBinding";
      metadata = {
        name = "hatchet-setup";
        inherit namespace;
      };
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "hatchet-setup";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "hatchet-setup";
          inherit namespace;
        }
      ];
    }

    (networkPolicy "default-deny" {
      podSelector = { };
      policyTypes = [
        "Ingress"
        "Egress"
      ];
    })
    (networkPolicy "dns-and-postgres" {
      podSelector = { };
      policyTypes = [ "Egress" ];
      egress = [
        {
          to = [
            {
              namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "kube-system";
              podSelector.matchLabels.k8s-app = "kube-dns";
            }
          ];
          ports =
            map
              (protocol: {
                inherit protocol;
                port = 53;
              })
              [
                "UDP"
                "TCP"
              ];
        }
        {
          to = [
            {
              namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "postgres";
              podSelector.matchLabels."cnpg.io/cluster" = "platform";
            }
          ];
          ports = [
            {
              protocol = "TCP";
              port = 5432;
            }
          ];
        }
      ];
    })
    # The API proxies to the engine, and the engine's internal client
    # connects to its own Service.
    (allow "hatchet-engine" "Ingress" (
      [
        (pods "hatchet-api")
        (pods "hatchet-engine")
      ]
      ++ lib.optional (cfg.clientNamespaces != [ ]) {
        namespaceSelector.matchExpressions = [
          {
            key = "kubernetes.io/metadata.name";
            operator = "In";
            values = cfg.clientNamespaces;
          }
        ];
      }
    ) grpcPort)
    (allow "hatchet-engine" "Egress" [ (pods "hatchet-engine") ] grpcPort)
    (allow "hatchet-api" "Egress" [ (pods "hatchet-engine") ] grpcPort)
    (allow "hatchet-api" "Ingress" [ (pods "hatchet-frontend") ] apiPort)
    (allow "hatchet-frontend" "Egress" [ (pods "hatchet-api") ] apiPort)
    # The API server listens on the host: the `kubernetes` Service
    # (10.43.0.1:443, ADR 0007) is translated to the node's address, port
    # 6443. Both, whichever of them kube-router matches.
    (allow "hatchet-setup" "Egress" [
      { ipBlock.cidr = "${config.backfabric.network.ipv4.address}/32"; }
    ] 6443)
    (allow "hatchet-setup" "Egress" [ { ipBlock.cidr = "10.43.0.1/32"; } ] 443)
  ];

  manifest =
    pkgs.runCommand "hatchet-${version}.yaml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
        objects = builtins.toJSON objects;
        passAsFile = [ "objects" ];
      }
      ''
        yq -P '.[] | split_doc' $objectsPath >$out
        unpinned=$(yq '[.. | select(tag == "!!map" and has("image")) | .image] | .[] | select(test("@sha256:[0-9a-f]{64}$") | not)' $out)
        if [[ -n $unpinned ]]; then
          echo "Image references without a digest in the Hatchet manifest:" >&2
          echo "$unpinned" >&2
          exit 1
        fi
      '';

  # The k3s manifests this module deploys, by name: deployed while it is
  # enabled, and removed (backfabric.k3s.removedManifests) while it is not.
  k3sManifests.hatchet.source = manifest;

  # The setup Job hatchet-credentials creates: `hatchet-admin` with the
  # Job's arguments. `hatchet-keys` is optional: the first Job writes it.
  setupJob = podSpec "hatchet-setup" {
    automountServiceAccountToken = true;
    serviceAccountName = "hatchet-setup";
    restartPolicy = "OnFailure";
    containers = [
      (container "setup" images.admin {
        command = [ "/hatchet/hatchet-admin" ];
        envFrom = [
          {
            secretRef = {
              name = "hatchet-keys";
              optional = true;
            };
          }
        ];
      })
    ];
  };

  k3s = lib.getExe' config.backfabric.k3s.package "k3s";
  shell = import ../lib/shell.nix;

  credentials = pkgs.writeShellApplication {
    name = "hatchet-credentials";
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
      wait_until 300 "the namespace ${namespace}; journalctl -u k3s | grep hatchet" exists namespace ${namespace}

      # run_job NAME ARGS...: hatchet-admin ARGS in a Job, waited for and
      # deleted; its log stays in the journal.
      run_job() {
        local name=hatchet-setup-$1
        shift
        kubectl -n ${namespace} delete job "$name" --ignore-not-found >/dev/null
        jq --arg name "$name" '{
          apiVersion: "batch/v1", kind: "Job",
          metadata: {name: $name, namespace: "${namespace}"},
          spec: {backoffLimit: 20, template: (.template | .spec.containers[0].args = $ARGS.positional)}
        }' --args -- "$@" <<<${lib.escapeShellArg (builtins.toJSON { template = setupJob; })} |
          kubectl create -f -
        if ! kubectl -n ${namespace} wait --for=condition=complete --timeout=600s "job/$name"; then
          kubectl -n ${namespace} logs "job/$name" --all-containers >&2 || true
          echo "The Job $name did not complete; kubectl -n ${namespace} describe job $name" >&2
          return 1
        fi
        kubectl -n ${namespace} logs "job/$name" --all-containers || true
        kubectl -n ${namespace} delete job "$name" >/dev/null
      }

      # The dashboard's admin, seeded by the API's init container. Hatchet
      # requires an upper-case letter, a lower-case letter and a digit
      # (`Aa1`); the rest is 192 random bits. Never in an argument or a file.
      if ! exists -n ${namespace} secret hatchet-admin; then
        PASSWORD=Aa1$(openssl rand -hex 24) jq -n '{
          apiVersion: "v1", kind: "Secret",
          metadata: {name: "hatchet-admin", namespace: "${namespace}"},
          stringData: {ADMIN_EMAIL: "admin@example.com", ADMIN_PASSWORD: env.PASSWORD}
        }' | kubectl create -f -
      fi

      # The encryption keys and cookie secrets; quickstart keeps existing
      # ones.
      if ! exists -n ${namespace} secret hatchet-keys; then
        run_job keys k8s quickstart --namespace ${namespace} --resource-name hatchet-keys
      fi

      # Whether the API is up (it seeds the admin and the tenant); quiet,
      # for polling.
      api_up() {
        [[ $(kubectl -n ${namespace} get deployment hatchet-api -o jsonpath='{.status.availableReplicas}' 2>/dev/null) -ge 1 ]]
      }

      # One token per client namespace, minted once (for the default
      # tenant, which the API's init container seeds), and copied to the
      # client's Secret `hatchet-client-token` at every run. Both Secrets
      # carry the label ${clientLabel}=<namespace>, by which the Secrets of
      # namespaces no longer listed are found and deleted below.
      clients=(${lib.escapeShellArgs cfg.clientNamespaces})
      for client in "''${clients[@]}"; do
        if ! exists -n ${namespace} secret "hatchet-token-$client"; then
          wait_until 900 "the Deployment ${namespace}/hatchet-api; kubectl -n ${namespace} describe deployment hatchet-api" api_up
          run_job "token-$client" k8s create-worker-token --namespace ${namespace} --resource-name "hatchet-token-$client"
        fi
        kubectl -n ${namespace} label --overwrite secret "hatchet-token-$client" "${clientLabel}=$client" >/dev/null
        exists namespace "$client" || kubectl create namespace "$client"
        kubectl -n ${namespace} get secret "hatchet-token-$client" -o json |
          CLIENT=$client jq '{
            apiVersion: "v1", kind: "Secret",
            metadata: {name: "hatchet-client-token", namespace: env.CLIENT, labels: {"${clientLabel}": env.CLIENT}},
            data: {
              HATCHET_CLIENT_TOKEN: .data.HATCHET_CLIENT_TOKEN,
              HATCHET_CLIENT_HOST_PORT: ("${engineAddress}" | @base64),
              HATCHET_CLIENT_TLS_STRATEGY: ("none" | @base64)
            }
          }' | kubectl apply --server-side --field-manager=hatchet-credentials -f -
      done

      # The Secrets of namespaces removed from clientNamespaces. The token
      # itself stays valid until it is revoked in the dashboard.
      listed=" ''${clients[*]} "
      kubectl get secret --all-namespaces -l ${clientLabel} -o json |
        jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name) \(.metadata.labels."${clientLabel}")"' |
        while read -r ns name client; do
          [[ $listed == *" $client "* ]] && continue
          echo "Deleting the Secret $ns/$name of $client, no longer in clientNamespaces; revoke its token in the dashboard."
          kubectl -n "$ns" delete secret "$name"
        done
    '';
  };
in
{
  options.backfabric.hatchet = {
    enable = lib.mkEnableOption "Hatchet, the platform's task queue, in the namespace `hatchet` (docs/hatchet.md)";

    clientNamespaces = lib.mkOption {
      # The setup Job's name, `hatchet-setup-token-<namespace>`, becomes a
      # label value: at most 63 characters.
      type = lib.types.listOf (lib.types.strMatching "[a-z0-9]([-a-z0-9]{0,41}[a-z0-9])?");
      default = [ ];
      example = [ "dispatcher" ];
      description = ''
        Namespaces whose pods may reach the engine's gRPC
        (${engineAddress}, without TLS). Each gets the Secret
        `hatchet-client-token` with a token of the default tenant and the
        Hatchet SDK's variables (HATCHET_CLIENT_TOKEN,
        HATCHET_CLIENT_HOST_PORT, HATCHET_CLIENT_TLS_STRATEGY), and is
        created if it does not exist.
      '';
    };
  };

  # Disabled: k3s removes what the manifest applied, with the namespace and
  # its Secrets (docs/hatchet.md, "Turning it off").
  config = lib.mkMerge [
    { backfabric.k3s.removedManifests = lib.mkIf (!cfg.enable) (lib.attrNames k3sManifests); }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.backfabric.postgres.enable;
          message = "backfabric.hatchet needs backfabric.postgres.enable";
        }
        {
          assertion = !lib.elem namespace cfg.clientNamespaces;
          message = "backfabric.hatchet.clientNamespaces must not contain ${namespace}";
        }
      ];

      backfabric.postgres.databases = [
        {
          name = "hatchet";
          owner = "hatchet";
          inherit namespace;
        }
      ];

      services.k3s.manifests = k3sManifests;

      # As postgres-credentials: waits for a bounded time and fails, at
      # every deployment and at boot.
      systemd.services.hatchet-credentials = {
        description = "Generate Hatchet's admin password, keys and client tokens";
        wantedBy = [ "multi-user.target" ];
        after = [
          "k3s.service"
          "postgres-credentials.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe credentials;
          TimeoutStartSec = "30min";
        };
      };
    })
  ];
}
