# CloudNativePG's release manifest (the operator, its CRDs, RBAC and
# webhooks), its image references pinned by digest. The build fails if a
# container image, or the operator's own image name (which it gives the
# instances' init container), is left without a digest. `postgresImage`:
# the PostgreSQL image of the Cluster, pinned as well.
#
# Upgrade: the version, the manifest's hash, and the digests (`crane digest
# <ref>`: the multi-platform index); the PostgreSQL image is the release's
# default (pkg/versions/versions.go), in its minimal variant.
{
  lib,
  runCommand,
  fetchurl,
  yq-go,
}:
let
  version = "1.30.1";
  images = {
    "ghcr.io/cloudnative-pg/cloudnative-pg:${version}" =
      "sha256:923c267ec29636db3bee20f993d0ec4973fa22998e1adad37da79e4d32b5bc07";
  };
in
runCommand "cnpg-${version}-pinned.yaml"
  {
    src = fetchurl {
      url = "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${version}/cnpg-${version}.yaml";
      hash = "sha256-NyN/FF2BOCVuolroMPh3WSVWZf8I+NVS/dgiSl7AMvs=";
    };
    nativeBuildInputs = [ yq-go ];
    passthru = {
      inherit version;
      postgresImage = "ghcr.io/cloudnative-pg/postgresql:18.6-minimal-trixie@sha256:ec2ed3404e89fff99643901b58a2a34c46a46345fe69a3d96500b82f995c327b";
    };
  }
  ''
    cp $src $out
    chmod u+w $out
    substituteInPlace $out ${
      lib.concatStringsSep " " (
        lib.mapAttrsToList (ref: digest: "--replace-fail ${ref} ${ref}@${digest}") images
      )
    }
    unpinned=$(yq '
      [.. | select(tag == "!!map") | (
        (select(has("image")) | .image | select(tag == "!!str")),
        (select(.name == "OPERATOR_IMAGE_NAME") | .value)
      )] | .[] | select(test("@sha256:[0-9a-f]{64}$") | not)' $out)
    if [[ -n $unpinned ]]; then
      echo "Image references without a digest in cnpg-${version}.yaml:" >&2
      echo "$unpinned" >&2
      exit 1
    fi
  ''
