# The container image of an agent, ghcr.io/backfabric/agent: Codex behind
# the A2A supervisor (agent/supervisor.py), run as an Agent Substrate actor.
# Built and published by .github/workflows/agent-image.yml; see
# docs/agent-image.md. Contains no secrets: each actor logs in to Codex at
# run time.
{
  lib,
  dockerTools,
  stdenvNoCC,
  fetchurl,
  bash,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  diffutils,
  gitMinimal,
  cacert,
  python3,
}:
let
  uid = 1000;
  gid = 1000;
  home = "/home/agent";

  # The supervisor's interpreter: the A2A SDK (its Starlette server) and
  # uvicorn.
  python = python3.withPackages (ps: [
    (ps.callPackage ../packages/a2a-sdk.nix { })
    ps.uvicorn
  ]);

  # Codex's own release, not nixpkgs (0.146.0 in NixOS 26.05). The package
  # archive is what upstream's install.sh installs: the static musl `codex`
  # with the helpers it looks for next to itself (`codex-code-mode-host`,
  # `codex-exec-server`) and in `codex-path`/`codex-resources` (rg, bwrap).
  # Version and hash from https://github.com/openai/codex/releases (the
  # asset's digest, also in `codex-package_SHA256SUMS`); the release also
  # has a Sigstore bundle for the archive (`<asset>.sigstore`, see
  # docs/agent-image.md).
  codex = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "codex";
    version = "0.167.2";
    src = fetchurl {
      url = "https://github.com/openai/codex/releases/download/rust-v${finalAttrs.version}/codex-package-x86_64-unknown-linux-musl.tar.gz";
      hash = "sha256-PXe+F0jTWkuw5/h1LN47EYkMYzOOjFmfAer6Slnhez0=";
    };
    sourceRoot = ".";
    installPhase = ''
      mkdir -p $out/libexec/codex $out/bin
      cp -r bin codex-path codex-resources codex-package.json $out/libexec/codex/
      ln -s $out/libexec/codex/bin/codex $out/bin/codex
    '';
    # Upstream's binaries as released: static, nothing to patch or strip.
    dontFixup = true;
    meta = {
      homepage = "https://github.com/openai/codex";
      license = lib.licenses.asl20;
      platforms = [ "x86_64-linux" ];
      mainProgram = "codex";
    };
  });

  # Written as regular files, not as store paths in `contents`: those become
  # absolute symlinks into /nix/store, and Agent Substrate's atelet reads
  # etc/passwd and etc/group to resolve the image's USER through os.Root,
  # inside each layer, so it rejects them ("path escapes from parent";
  # cmd/atelet/oci.go, internal/imagecache/imagefile.go at v1.0.0) and the
  # actor crashes before it starts.
  passwd = ''
    root:x:0:0:root:/root:${bash}/bin/bash
    agent:x:${toString uid}:${toString gid}:agent:${home}:${bash}/bin/bash
  '';
  group = ''
    root:x:0:
    agent:x:${toString gid}:
  '';
in
dockerTools.buildLayeredImage {
  name = "ghcr.io/backfabric/agent";
  contents = [
    bash
    coreutils
    findutils
    gnugrep
    gnused
    diffutils
    gitMinimal
    cacert
    python
    codex
  ];
  fakeRootCommands = ''
    mkdir -p etc .${home} tmp usr/bin
    printf %s ${lib.escapeShellArg passwd} > etc/passwd
    printf %s ${lib.escapeShellArg group} > etc/group
    chmod 0644 etc/passwd etc/group
    for f in etc/passwd etc/group; do
      if [ -L "$f" ] || [ ! -f "$f" ]; then
        echo "$f must be a regular file (atelet rejects symlinks)" >&2
        exit 1
      fi
    done
    chown ${toString uid}:${toString gid} .${home}
    chmod 1777 tmp
    ln -s ${coreutils}/bin/env usr/bin/env
  '';
  config = {
    User = "${toString uid}:${toString gid}";
    WorkingDir = home;
    Entrypoint = [
      "${python}/bin/python3"
      "-u"
      "${../../agent/supervisor.py}"
    ];
    # Port 80 needs NET_BIND_SERVICE, which a non-root actor process does
    # not get (no ambient capabilities in Substrate's sandboxes).
    ExposedPorts."8080/tcp" = { };
    Env = [
      "PATH=/bin"
      "HOME=${home}"
      # Codex's login (auth.json), configuration and sessions: the home
      # directory is the agent's state, see docs/agent-image.md.
      "CODEX_HOME=${home}/.codex"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
    # Links the package to the repository at its first push.
    Labels = {
      "org.opencontainers.image.source" = "https://github.com/backfabric/infra";
      "org.opencontainers.image.description" = "Codex agent run as an Agent Substrate actor";
    };
  };
}
