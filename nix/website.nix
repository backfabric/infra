# The project website (website/, https://backfabric.dev): the static site
# Eleventy generates from website/ and from the repository's own docs, read
# in place (ADR 0026). Published to GitHub Pages by
# .github/workflows/website.yml.
{ lib, buildNpmPackage }:

buildNpmPackage {
  pname = "backfabric-website";
  version = "0";

  # Only the files the site is built from, so that changes to Nix code or
  # workflows do not rebuild it.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../website
      ../docs
      ../README.md
      ../nix/templates/default/README.md
    ];
  };
  sourceRoot = "source/website";

  npmDepsHash = "sha256-7Z5znsRFn5xtQ101XfX1DByDv9xSyP8vUUjGKI/EHOk=";

  installPhase = ''
    runHook preInstall
    cp -r _site $out
    runHook postInstall
  '';

  meta = {
    description = "The backfabric project website";
    homepage = "https://backfabric.dev";
    license = lib.licenses.mit;
  };
}
