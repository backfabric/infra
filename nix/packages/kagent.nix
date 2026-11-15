# The kagent CLI, the release binary of kagent-dev/kagent for the host's
# platform (statically linked Go), pinned by hash, without kagent's
# install script. Used by nix/modules/kagent.nix (`kagent install`).
#
# Upgrade: the version and both hashes, the SHA-256 of the release's
# `kagent-linux-<arch>.sha256` files (`nix hash convert --hash-algo sha256
# --to sri <hex>`). The CLI pins the chart versions it installs.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "1.0.1";
  assets = {
    x86_64-linux = {
      arch = "amd64";
      hash = "sha256-8YgYKq9EXlcHq400WPOU+jD4dcwXhuxPEqMLn6Co138=";
    };
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-puyYCQlM2rDz3m9mIwn2rM+mRcuNXuwVUUaWicc1ieU=";
    };
  };
  asset =
    assets.${stdenvNoCC.hostPlatform.system}
      or (throw "kagent: no release binary for ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "kagent";
  inherit version;

  src = fetchurl {
    url = "https://github.com/kagent-dev/kagent/releases/download/v${version}/kagent-linux-${asset.arch}";
    inherit (asset) hash;
  };

  dontUnpack = true;
  installPhase = ''
    install -Dm755 $src $out/bin/kagent
  '';

  meta = {
    description = "The kagent CLI";
    homepage = "https://kagent.dev/";
    license = lib.licenses.asl20;
    platforms = lib.attrNames assets;
    mainProgram = "kagent";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
