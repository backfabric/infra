# The dispatcher's container image, ghcr.io/backfabric/dispatcher (ADR
# 0028, amending ADR 0022): the static binary and the CA bundle, nothing
# else (no shell, no package manager). Runs as a non-root user with a
# read-only root file system: it writes nothing but to the network.
# Built and published by .github/workflows/dispatcher-image.yml.
{
  dockerTools,
  cacert,
  dispatcher,
}:
let
  # A numeric user, so the image needs no /etc/passwd.
  uid = 65532;
in
dockerTools.buildLayeredImage {
  name = "ghcr.io/backfabric/dispatcher";
  # The image's only store paths are the closure of its configuration:
  # the binary and the CA bundle.
  config = {
    User = "${toString uid}:${toString uid}";
    Entrypoint = [ "${dispatcher}/bin/dispatcher" ];
    ExposedPorts."8080/tcp" = { };
    Env = [ "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt" ];
    # Links the package to the repository at its first push.
    Labels = {
      "org.opencontainers.image.source" = "https://github.com/backfabric/infra";
      "org.opencontainers.image.description" = "The dispatcher: the A2A front door for agent tasks";
    };
  };
}
