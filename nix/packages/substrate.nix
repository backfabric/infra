# Agent Substrate (https://github.com/agent-substrate/substrate) at a
# release tag: its installer `ate-setup` and the kubectl plugin
# `kubectl-ate`, built from source, and `manifests`, the part of the source
# tree `ate-setup` reads at run time, with this repository's patches.
#
# `ate-setup` finds its manifests by walking up from the working directory
# to the first `go.mod` (cmd/ate-setup/internal/config/shellenv.go
# RepoRoot) and applies fixed paths below it: the base kustomization
# (manifests/ate-install/base) for every install that is not kind, and
# single files for the bundled PostgreSQL, the pod certificate controller
# and the OTel ConfigMap (cmd/ate-setup/internal/steps/overlay.go,
# postgres.go, deploy.go). It cannot be pointed at an overlay of its own,
# so the patches go into those paths here: as kustomize patches in the base
# kustomization where it has one, and in the file itself where `ate-setup`
# reads a single file. `ate-setup` must run with `manifests` as its working
# directory.
{
  lib,
  buildGo127Module,
  fetchFromGitHub,
  kustomize,
  runCommand,
  yq-go,
}:
let
  version = "1.0.0";
  # The commit the annotated tag v1.0.0 points at.
  commit = "b34fbee742906494b5eb4f1f36987176bf8770a4";

  src = fetchFromGitHub {
    owner = "agent-substrate";
    repo = "substrate";
    rev = "v${version}";
    hash = "sha256-smq4+HxT7vaqhomfTGCIa3ndq1UqsfMKON4DVhTl/o0=";
  };

  # The release's images, by the name ate-setup publishes them as (the base
  # name of the Go package, cmd/ate-setup/internal/images/images.go), with
  # the digest of the multi-platform index the tag v1.0.0 points at.
  # ate-setup resolves the tags at install time and writes
  # `<repo>/<name>:<tag>@<digest>` into the pods
  # (cmd/ate-setup/internal/images/prebuilt.go Prebuilt.Pin); these pins
  # are what it must find. Only the images ate-system's pods and gVisor
  # workers run.
  imageRepo = "ghcr.io/agent-substrate/substrate";
  imageTag = "v${version}";
  imageDigests = {
    ate-idp-server = "sha256:9553c0e60a8ad8bbb1c54c59e59cf0d33a338bf4f883b6f806610dc407f49f7c";
    ateapi = "sha256:2f1ee444b126b6e3620045b61d2a87507fb0f889da0249656c474ab59dc2beaf";
    atecontroller = "sha256:44b3a127048e1da8c15dff35f65defe73f4e54ebb985bc020aa9bb0e6eb029b2";
    atelet = "sha256:79abc69f982392adbcbc3332cd8191cf74ac3cd1f4a43c44e9c8a3ce16488b6e";
    atenet = "sha256:04f7d93dc3fb3deda688137077226c12ce2da41cd4753adff708e3737dc59e20";
    objectstore-plugin = "sha256:485cf92b31fed761c53f478d17ed69bf552a2cd8e8cf3b24b98a3e06789ee274";
    # Built from cmd/dataplane/envoy/Dockerfile; ate-setup substitutes it
    # for ${ENVOY_DATAPLANE_IMAGE} (steps/overlay.go).
    envoy-dataplane = "sha256:fc8e4c3ee9060a01153e4d4af571f3db294e60d536422e8a8c2996fa4a72bf8b";
    ateworker-gvisor = "sha256:f8987236c6256f58c4b2625e543b43f4ae4bdded6ee6821c03d966effb7c0f17";
  };
  image = name: "${imageRepo}/${name}:${imageTag}@${imageDigests.${name}}";

  # Every image the pods ate-setup creates in ate-system can run: the
  # control plane bundle (manifests/ate-install/base), atenet-egress.yaml
  # and the bundled PostgreSQL (pinned by upstream in
  # postgres/postgres.yaml). The build of `manifests` checks that this is
  # exactly the set those patched manifests produce.
  systemImages =
    map image [
      "ate-idp-server"
      "ateapi"
      "atecontroller"
      "atelet"
      "atenet"
      "objectstore-plugin"
      "envoy-dataplane"
    ]
    ++ [
      "postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15"
    ];

  # The in-cluster RustFS, deployed by nix/modules/substrate.nix from these
  # names: its Service, the Secret with its credentials (in the namespace of
  # every pod that uses it) and that Secret's keys.
  # The namespace `deploy ate-system` installs into; it refuses any other
  # (RequireCanonicalNamespace).
  namespace = "ate-system";

  rustfs = rec {
    service = "rustfs";
    inherit namespace;
    port = 9000;
    endpoint = "http://${service}.${namespace}.svc:${toString port}";
    # RustFS ignores the region; the AWS SDK needs one.
    region = "us-east-1";
    secret = "rustfs-credentials";
    accessKeyKey = "access-key";
    secretKeyKey = "secret-key";
  };

  # The objectstore-plugin sidecars of atelet (node mode: snapshot
  # transfers) and ate-api-server (control mode: copies and deletes
  # snapshots) select GCS unless ATE_STORAGE_BACKEND is `s3`
  # (pkg/objectstorage/env.go). These are the settings of upstream's kind
  # overlay (manifests/ate-install/kind/{atelet,ate-api-server}) for the
  # in-cluster RustFS, except that the credentials come from a Secret
  # instead of literals. On S3 the node plugin transfers with these
  # credentials and never calls the control sidecar's credential exchange
  # (cmd/objectstore-plugin/exchange.go).
  s3Env = [
    {
      name = "ATE_STORAGE_BACKEND";
      value = "s3";
    }
    {
      name = "AWS_REGION";
      value = rustfs.region;
    }
    {
      name = "AWS_ENDPOINT_URL";
      value = rustfs.endpoint;
    }
    {
      name = "AWS_S3_USE_PATH_STYLE";
      value = "true";
    }
    {
      name = "AWS_ACCESS_KEY_ID";
      valueFrom.secretKeyRef = {
        name = rustfs.secret;
        key = rustfs.accessKeyKey;
      };
    }
    {
      name = "AWS_SECRET_ACCESS_KEY";
      valueFrom.secretKeyRef = {
        name = rustfs.secret;
        key = rustfs.secretKeyKey;
      };
    }
  ];

  objectstoreSidecar = {
    name = "objectstore-plugin";
    env = s3Env;
  };

  # Strategic merge patches: `env` merges by name (replacing the base's
  # ATE_STORAGE_BACKEND=gcs), containers and volumes by name, volumeMounts
  # by mountPath.
  basePatches = [
    {
      patch = builtins.toJSON {
        apiVersion = "apps/v1";
        kind = "DaemonSet";
        metadata = {
          name = "atelet";
          namespace = "ate-system";
        };
        spec.template.spec = {
          initContainers = [ objectstoreSidecar ];
          # GKE's kubelet credential provider (/home/kubernetes/bin,
          # /etc/srv/kubernetes/cri_auth_config.yaml): k3s nodes have none,
          # and the hostPath volumes would create both paths on the host
          # (DirectoryOrCreate, FileOrCreate). Removed as upstream's kind
          # overlay removes them; atelet then pulls actor images
          # anonymously, so actor images must be public.
          containers = [
            {
              name = "atelet";
              volumeMounts = [
                {
                  mountPath = "/run/image-credential-provider/bin";
                  "$patch" = "delete";
                }
                {
                  mountPath = "/run/image-credential-provider/config.yaml";
                  "$patch" = "delete";
                }
              ];
            }
          ];
          volumes = [
            {
              name = "image-credential-provider-bin";
              "$patch" = "delete";
            }
            {
              name = "image-credential-provider-config";
              "$patch" = "delete";
            }
          ];
        };
      };
    }
    # The flags that point atelet at those files. The kind overlay replaces
    # the whole argument list instead; removing exactly these two keeps the
    # other flags of the release. `test` makes the build of the
    # kustomization fail if a later release reorders the arguments.
    {
      target = {
        kind = "DaemonSet";
        name = "atelet";
        namespace = "ate-system";
      };
      patch = builtins.toJSON [
        {
          op = "test";
          path = "/spec/template/spec/containers/0/args/0";
          value = "--image-credential-provider-config=/run/image-credential-provider/config.yaml";
        }
        {
          op = "remove";
          path = "/spec/template/spec/containers/0/args/0";
        }
        {
          op = "test";
          path = "/spec/template/spec/containers/0/args/0";
          value = "--image-credential-provider-bin-dir=/run/image-credential-provider/bin";
        }
        {
          op = "remove";
          path = "/spec/template/spec/containers/0/args/0";
        }
      ];
    }
    {
      patch = builtins.toJSON {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = {
          name = "ate-api-server";
          namespace = "ate-system";
        };
        spec.template.spec.initContainers = [ objectstoreSidecar ];
      };
    }
  ];

  # Replaces the release's OTel ConfigMap, whose endpoint is GKE's managed
  # collector: no component exports traces or metrics (`none`, which
  # internal/serverboot/exporters.go accepts for every signal; it also
  # turns off the Prometheus pull endpoints), logs go to the console, and
  # no OTLP endpoint is set. The worker pods get the same through
  # ate-controller's ATE_WORKER_OTEL_* variables
  # (cmd/atecontroller/main.go). The host's Collector (ADR 0021) needs a
  # service account token with audience `otel-collector`, which Substrate's
  # exporters do not send.
  otelConfig = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "ate-otel-config";
      namespace = "ate-system";
    };
    data = {
      OTEL_TRACES_EXPORTER = "none";
      OTEL_METRICS_EXPORTER = "none";
      OTEL_LOGS_EXPORTER = "console";
      ATE_WORKER_OTEL_TRACES_EXPORTER = "none";
      ATE_WORKER_OTEL_METRICS_EXPORTER = "none";
      ATE_WORKER_OTEL_LOGS_EXPORTER = "console";
    };
  };

  # The size of the bundled PostgreSQL's volume claim. The release asks for
  # 500Gi; the claim binds to a static local volume of the host
  # (nix/modules/substrate.nix), whose size the claim must not exceed. A
  # volumeClaimTemplate cannot change after the StatefulSet exists.
  postgresStorage = "10Gi";

  ateSetup = buildGo127Module {
    pname = "agent-substrate";
    inherit version src;
    # The repository vendors its dependencies.
    vendorHash = null;
    subPackages = [
      "cmd/ate-setup"
      "cmd/kubectl-ate"
    ];
    env.CGO_ENABLED = "0";
    ldflags = [
      "-s"
      "-X go.ate.dev/substrate/internal/version.Version=v${version}"
      "-X go.ate.dev/substrate/internal/version.Commit=${commit}"
    ];
    # The tests need a cluster, Docker or the network for many cases; this
    # package only builds the release.
    doCheck = false;
    meta = {
      description = "Agent Substrate's installer (ate-setup) and kubectl plugin (kubectl-ate)";
      homepage = "https://github.com/agent-substrate/substrate";
      license = lib.licenses.asl20;
      mainProgram = "ate-setup";
    };
  };

  # go.mod marks the root for ate-setup; manifests/ is all it reads for
  # `deploy ate-system`.
  manifests =
    runCommand "agent-substrate-manifests-${version}"
      {
        nativeBuildInputs = [
          kustomize
          yq-go
        ];
        basePatches = builtins.toJSON basePatches;
        otelConfig = builtins.toJSON otelConfig;
        imageDigests = builtins.toJSON imageDigests;
        systemImages = lib.concatLines systemImages;
        passAsFile = [
          "basePatches"
          "otelConfig"
          "imageDigests"
          "systemImages"
        ];
      }
      ''
        mkdir -p $out
        cp ${src}/go.mod $out/
        cp -r ${src}/manifests $out/
        chmod -R u+w $out/manifests
        install=$out/manifests/ate-install

        # The base kustomization has no patches of its own.
        [[ $(yq '.patches // [] | length' $install/base/kustomization.yaml) == 0 ]]
        patches=$basePatchesPath yq -i '.patches = load(strenv(patches))' \
          $install/base/kustomization.yaml

        # atenet-router-monitoring.yaml is a PodMonitoring
        # (monitoring.googleapis.com/v1) for Google Managed Prometheus, a
        # GKE-only CRD: on any other cluster the apply fails ("no matches for
        # kind PodMonitoring"). Upstream's kind overlay leaves it out too.
        monitoring=../atenet-router-monitoring.yaml
        [[ $(m=$monitoring yq '[.resources[] | select(. == strenv(m))] | length' $install/base/kustomization.yaml) == 1 ]]
        m=$monitoring yq -i 'del(.resources[] | select(. == strenv(m)))' \
          $install/base/kustomization.yaml

        yq -o yaml -P . $otelConfigPath >$install/ate-otel-config.yaml

        # The release's size, checked so that a new release that changes it
        # fails here instead of being overwritten unseen.
        claim='.spec.volumeClaimTemplates[0].spec.resources.requests.storage'
        [[ $(yq "select(.kind == \"StatefulSet\") | $claim" $install/postgres/postgres.yaml) == 500Gi ]]
        yq -i "(select(.kind == \"StatefulSet\") | $claim) = \"${postgresStorage}\"" \
          $install/postgres/postgres.yaml

        # The pod certificate controller sets no seccomp profile (pod
        # securityContext {}), which Pod Security `restricted` requires;
        # everything else in its pod already passes. RuntimeDefault keeps
        # its namespace under `restricted`.
        yq -i '(select(.kind == "Deployment") | .spec.template.spec.securityContext.seccompProfile.type) = "RuntimeDefault"' \
          $install/pod-certificate-controller.yaml

        # systemImages is exactly what the patched manifests of ate-system's
        # pods produce once ate-setup has resolved them: ko://<module>/cmd/<name>
        # and ''${ENVOY_DATAPLANE_IMAGE} become <repo>/<name>:<tag>@<digest>,
        # other references stay as written.
        {
          kustomize build --load-restrictor LoadRestrictionsNone $install/base
          echo ---
          cat $install/atenet-egress.yaml
          echo ---
          cat $install/postgres/postgres.yaml
        } | yq ea -N '.. | select(tag == "!!map" and has("image")) | .image' |
          while read -r ref; do
            case $ref in
              ko://go.ate.dev/substrate/*) name=''${ref##*/} ;;
              '${"$"}{ENVOY_DATAPLANE_IMAGE}') name=envoy-dataplane ;;
              *) echo "$ref"; continue ;;
            esac
            digest=$(name=$name yq -e '.[strenv(name)]' $imageDigestsPath) || {
              echo "no pinned digest for $name ($ref)" >&2
              exit 1
            }
            echo "${imageRepo}/$name:${imageTag}@$digest"
          done | sort -u >images
        sort -u $systemImagesPath | diff -u - images

        # Every object ate-setup applies for this install (deploy ate-system:
        # non-kind, envoy, gVisor only, no CSI, Cloud SQL or credential
        # provider; cmd/ate-setup/internal/steps) must be of an API group the
        # cluster serves without anything else installed: Kubernetes' own
        # ("" and apps, batch, autoscaling, policy, *.k8s.io) or a group of
        # a CRD in the tree. A resource of another group (a cloud provider's
        # CRD) fails here instead of in the install.
        applied=(
          ate-system-namespace.yaml
          generated/ate.dev_csidriverconfigs.yaml
          generated/ate.dev_sandboxconfigs.yaml
          generated/ate.dev_workerpools.yaml
          generated/role.yaml
          sandboxconfig-validation.yaml
          sandboxconfig-gvisor.yaml
          pod-certificate-controller.yaml
          ate-otel-config.yaml
          postgres/postgres.yaml
          atenet-egress.yaml
        )
        {
          kustomize build --load-restrictor LoadRestrictionsNone $install/base
          for file in "''${applied[@]}"; do
            echo ---
            cat "$install/$file"
          done
        } >applied.yaml
        yq -N 'select(.kind == "CustomResourceDefinition") | .spec.group' applied.yaml |
          sort -u >crd-groups
        yq -N 'select(.apiVersion != null) | .apiVersion + " " + .kind + " " + (.metadata.namespace // "-") + "/" + .metadata.name' \
          applied.yaml |
          while read -r apiVersion kind name; do
            group=''${apiVersion%/*}
            [[ $apiVersion == */* ]] || group=""
            case $group in
              "" | apps | batch | autoscaling | policy | *.k8s.io) ;;
              *) grep -qxF "$group" crd-groups || echo "$apiVersion $kind $name" ;;
            esac
          done >foreign
        if [[ -s foreign ]]; then
          echo "ate-setup would apply objects of API groups no CRD in the tree defines:" >&2
          cat foreign >&2
          exit 1
        fi
      '';
in
ateSetup.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit
      manifests
      namespace
      rustfs
      systemImages
      ;
    workerImage = image "ateworker-gvisor";
  };
})
