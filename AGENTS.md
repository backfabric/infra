# AGENTS.md

Public NixOS flake: modules for an encrypted k3s cluster on Hetzner bare
metal, plus the operator tooling (`fleet/`) and the template of the private
repository that consumes them. Layout and subsystems: [README.md](README.md).

Architectural decisions and their reasons: [docs/adr/](docs/adr/). Read the
matching ADR before changing disks, boot, networking, access, the cluster,
secrets, installation, deployment, or the operator tooling; a change that
contradicts an ADR is put to the user first, and an accepted new decision of
that weight (hard to reverse, surprising, a real trade-off) gets its own ADR
in the same PR.

## Boundary

- This repository is public and consumer-agnostic. Host data (IPs, MACs, disk
  ids, facter reports, keys, secrets) lives only in the user's private
  repository; examples use documentation values (RFC 5737/3849/7042).
- Public code leaves the operator's personal setup to the operator: the type
  and location of sops admin keys, SSH client keys and agents, the password
  manager, `~/.ssh` (documented lines the user adds by hand, never written by
  code).

## Workflow

- One GitHub issue and one PR per change. Every PR targets `main`; work that
  depends on an unmerged PR waits for its merge and is then branched from
  `main`.
- The user reviews and merges every PR; agents push only to their own branch.
- Conventional Commits for every commit message and PR title (`feat:`,
  `fix:`, `refactor:`, `docs:`, `chore:`, `ci:`). Issue titles are plain
  English.
- Everything in the repository and on GitHub is in English, whatever language
  the conversation uses.
- The PR body lists every decision the issue did not settle, especially
  choices that are non-default, non-standard, or add complexity, so the user
  can review them. Irreversible choices (anything that would need a cluster
  rebuild) are put to the user before implementation.

## Design

- Prefer upstream NixOS options and established tools over own code; add an
  option only when a consumer needs it.
- A module or command exists only with real behaviour.
- Subsystem layout contract: `modules/<subsystem>.nix`, options under
  `backfabric.<subsystem>`, registered explicitly in `modules/default.nix`.
- Operator commands are subcommands of `backfabric` in bash under
  `fleet/cli/` (one file per subcommand, shared helpers in `lib.sh`, built as
  one `writeShellApplication`, so shellcheck runs at build time). Each
  subcommand does one thing, can be re-run after a failure, and prints the
  next step.

## Verification

- Before pushing: `nix fmt -- --ci` and `nix flake check --no-build
  --all-systems` (CI runs the same, evaluation only).
- The development machine is aarch64-darwin without a Linux builder:
  x86_64-linux configurations can only be evaluated. aarch64-darwin outputs
  (the `backfabric` package, `devShells.<system>.example-fleet`) can be built
  and run; exercise CLI changes in a mock private repository created with
  `nix flake init -t`, with stubs for the server side.
- The PR body states what was verified and what still needs a real server.
- When user-facing behaviour changes, update the matching runbook in `docs/`,
  the README, and `templates/default/README.md`.
