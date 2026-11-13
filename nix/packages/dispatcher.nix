# The dispatcher (ADR 0028), the A2A front door for agent tasks, from the
# Go module in ../../dispatcher; see dispatcher/README.md. Go 1.27: the
# module will import Substrate's API client (go.ate.dev/substrate, `go
# 1.27.0`), as nix/packages/substrate.nix builds it.
{
  lib,
  stdenv,
  buildGo127Module,
  postgresql_18,
  postgresqlTestHook,
}:
buildGo127Module {
  pname = "dispatcher";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../../dispatcher;
    fileset = ../../dispatcher;
  };
  vendorHash = "sha256-tBiZlsVDiq002qVyOMU+0wxtBoVDeXnxwJPhm8Yg19I=";
  env = {
    CGO_ENABLED = "0";
  }
  // lib.optionalAttrs stdenv.hostPlatform.isLinux {
    # Where the hook runs, a test that cannot reach it fails, not skips.
    DISPATCHER_TEST_DATABASE = "required";
  };
  ldflags = [ "-s" ];

  # The tests that need the record run against a real PostgreSQL, the
  # platform's major version (ADR 0025), started for the check phase; the
  # others start JWT issuers and the dispatcher on loopback. nixpkgs'
  # hook does not run on Darwin (shared memory in its sandbox), where
  # those tests are skipped; CI builds on Linux.
  nativeCheckInputs = lib.optionals stdenv.hostPlatform.isLinux [
    postgresql_18
    postgresqlTestHook
  ];
  __darwinAllowLocalNetworking = true;
  # staticcheck (go-tools 2026.1 in nixpkgs) cannot read Go 1.27's export
  # data yet; vet and gofmt come with the toolchain.
  preCheck = ''
    unformatted=$(gofmt -l ./*.go)
    if [[ -n $unformatted ]]; then
      echo "not formatted with gofmt:" $unformatted >&2
      exit 1
    fi
    go vet ./...
  '';

  meta = {
    description = "The A2A front door for agent tasks";
    homepage = "https://github.com/backfabric/infra";
    license = lib.licenses.mit;
    mainProgram = "dispatcher";
  };
}
