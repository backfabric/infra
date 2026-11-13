# The A2A Python SDK at a release that speaks A2A 1.0, for the agent
# supervisor (agent/, docs/agent-image.md). nixpkgs has 0.3.x, which speaks
# A2A 0.3 only. The server side, with the `http-server` extra (Starlette);
# without the optional database, gRPC, signing and telemetry extras.
#
# Upgrade: version and hash of the sdist on https://pypi.org/project/a2a-sdk/
# (`nix-prefetch-url` or the hash mismatch of a build), then the
# dependencies against its pyproject.toml.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  hatchling,
  uv-dynamic-versioning,
  google-api-core,
  googleapis-common-protos,
  httpx,
  json-rpc,
  packaging,
  protobuf,
  pydantic,
  sse-starlette,
  starlette,
}:
buildPythonPackage rec {
  pname = "a2a-sdk";
  version = "1.3.0";
  pyproject = true;

  src = fetchPypi {
    pname = "a2a_sdk";
    inherit version;
    hash = "sha256-c2lHF95Q82quvVe4/GY27KqCXrDUQ3mE+izRf3A6aAg=";
  };

  build-system = [
    hatchling
    uv-dynamic-versioning
  ];

  dependencies = [
    google-api-core
    googleapis-common-protos
    httpx
    json-rpc
    packaging
    protobuf
    pydantic
    # The `http-server` extra.
    sse-starlette
    starlette
  ];

  # The sdist has no tests.
  doCheck = false;
  pythonImportsCheck = [
    "a2a.server.routes"
    "a2a.server.request_handlers"
  ];

  meta = {
    description = "Python SDK for the Agent2Agent (A2A) protocol";
    homepage = "https://github.com/a2aproject/a2a-python";
    changelog = "https://github.com/a2aproject/a2a-python/blob/v${version}/CHANGELOG.md";
    license = lib.licenses.asl20;
  };
}
