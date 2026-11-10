# backfabric <command>: the dispatcher, after the subcommands. See
# docs/fleet-shell.md.

usage() {
  cat <<'EOF'
Usage: backfabric <command> [<argument>...]

Commands for the hosts of the private repository, run from its root:
  sops init       Create .sops.yaml with the admin keys, once
  install         Install a host from the Hetzner Rescue system
  sops add-host   Add a host to .sops.yaml and re-encrypt its files
  help            Show this help, or the help of a command

Run `backfabric help <command>` or `backfabric <command> --help` for the
arguments of a command.
EOF
}

usage_error() {
  usage >&2
  exit 2
}

cmd_help() {
  case "$*" in
  "" | -h | --help | help)
    usage
    ;;
  install | "sops init" | "sops add-host")
    main "$@" --help
    ;;
  *)
    usage_error
    ;;
  esac
}

main() {
  case "${1-}" in
  install)
    shift
    cmd_install "$@"
    ;;
  sops)
    case "${2-}" in
    init)
      shift 2
      cmd_sops_init "$@"
      ;;
    add-host)
      shift 2
      cmd_sops_add_host "$@"
      ;;
    *)
      usage_error
      ;;
    esac
    ;;
  help)
    shift
    cmd_help "$@"
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage_error
    ;;
  esac
}

main "$@"
