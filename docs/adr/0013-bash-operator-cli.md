# One `backfabric` command in bash

Operator tooling is one command with subcommands (`nix/fleet/cli/`), written in bash and built as a single `writeShellApplication`, so shellcheck runs at build time and every subcommand shares helpers. Nushell was considered for its structured data handling and rejected for now: it is pre-1.0 and breaks between minor versions, the command is built from the consumer's nixpkgs (ADR 0002), there is no shellcheck equivalent, and the scripts had not yet been validated on a real server.
