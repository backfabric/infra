# backfabric deploy: applies the committed configuration to an installed
# host, built on the host itself. See docs/fleet-shell.md.

usage_deploy() {
  cat <<'EOF'
Usage: backfabric deploy <host> [switch | boot | test]

Run inside the fleet dev shell (with `Include ${PROJECT_SSH_CONFIG}` as the
first line of ~/.ssh/config), from the root of the private repository.
Applies nixosConfigurations.<host> of the committed HEAD to the installed
host (default: switch):

  nixos-rebuild <action> --flake .#<host> --target-host <host>
    --build-host <host> --no-reexec --use-substitutes

The operator machine only evaluates; the host builds its own system
(--build-host), fetching what it can from the binary cache
(--use-substitutes). --no-reexec skips nixos-rebuild's local build of the new
configuration's own nixos-rebuild, which another platform (macOS) cannot
build. Refuses if tracked files have uncommitted changes. Nothing rolls back
automatically: if a change breaks networking or SSH, recover from the
Hetzner Rescue system.
EOF
}

cmd_deploy() {
  prog="backfabric deploy"

  case "${1-}" in
  -h | --help)
    usage_deploy
    exit 0
    ;;
  esac
  if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage_deploy >&2
    exit 2
  fi
  host=$1
  action=${2:-switch}
  case $action in
  switch | boot | test) ;;
  *)
    usage_deploy >&2
    exit 2
    ;;
  esac

  check_host_name "$host"
  require_flake
  require_host "$host"
  require_fleet_ssh "$host"

  # What is deployed must be a commit: the flake sees the working tree.
  git diff --quiet HEAD ||
    die "uncommitted changes in tracked files; commit them first (git status)"

  echo "Deploying $(git rev-parse --short HEAD) to $host ($action), built on $host ..."
  nixos-rebuild "$action" --flake ".#$host" \
    --target-host "$host" --build-host "$host" \
    --no-reexec --use-substitutes
}
