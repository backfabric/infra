# backfabric <command>: the dispatcher, after the subcommands. See
# docs/fleet-shell.md.

usage() {
  cat <<'EOF'
Usage: backfabric <command> [<argument>...]

Commands for the hosts of the private repository, run from its root, in the
order of a host's installation, then for its updates:
  sops init       Create .sops.yaml with the admin keys, once
  keygen          Generate a host's keys and LUKS passphrase, locally
  sops add-host   Add a host to .sops.yaml and re-encrypt its files
  probe           Boot the server into the installer, get its hardware report
  install         Install a host on the server (erases its disks)
  unlock          Send the LUKS passphrase to a host's initrd (every boot)
  finalize        Check the installed host and delete its local secrets
  deploy          Apply the committed configuration, built on the host
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
  "sops init" | keygen | "sops add-host" | probe | install | unlock | finalize | deploy)
    main "$@" --help
    ;;
  *)
    usage_error
    ;;
  esac
}

main() {
  case "${1-}" in
  keygen | probe | install | unlock | finalize | deploy)
    command=$1
    shift
    "cmd_$command" "$@"
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
