---
status: amended by ADR 0026
---

# CI builds and publishes the agent image

Amends ADR 0015. CI builds and publishes exactly one artifact: the agents' container image, `ghcr.io/backfabric/agent` (`packages.x86_64-linux.agent-image`, `nix/images/`). Agents run as Agent Substrate actors, and an actor's image must be pullable by the cluster, anonymously (the `substrate` subsystem, ADR 0023, gives atelet no registry credentials). The image holds no secrets, only Codex, a small supervisor and basic tools; every agent logs in to Codex at run time. So it can be public and built in this public repository, with Nix like everything else here. Everything else in CI stays evaluation only.

The workflow `.github/workflows/agent-image.yml` builds the image on every pull request that touches it and starts it once (no write permissions, nothing pushed), and on pushes to main publishes it tagged with the full commit SHA, with a build provenance attestation. Consumers (the private repository) pin the image by digest. There is no `latest` tag.

## Considered Options

- A Dockerfile and `docker build`: a second build system beside Nix, with unpinned base images and package managers.
- Codex from nixpkgs: NixOS 26.05 has 0.146.0, 21 minor releases behind; Codex changes fast and the login and `exec` flags matter. The image takes Codex's own release archive instead, pinned by hash.
- A private registry, or a private package on ghcr.io: needs pull credentials in the cluster for an image without secrets. Possible later if the image ever must not be public.
- Building on the operator machine: aarch64-darwin without a Linux builder cannot build an x86_64-linux image.

## Consequences

- The `publish` job is the first CI job with write permissions (`packages`, `id-token`, `attestations`), scoped to that job and to pushes on main; pull requests run with `contents: read` only.
- A package published by a workflow is private at first: it inherits the repository's access permissions, not its visibility. An organization owner makes it public once, by hand: <https://github.com/orgs/backfabric/packages/container/agent/settings>, "Danger Zone", "Change visibility", "Public" (irreversible; the organization's "Package Creation" settings must allow public packages).
- Every published digest has a signed SLSA build provenance attestation, stored by GitHub and pushed to the registry next to the image: `gh attestation verify oci://ghcr.io/backfabric/agent@<digest> --owner backfabric`.
- Bumping Codex means changing its version and hash in `nix/images/agent.nix`; the image changes with `flake.lock` as well.
