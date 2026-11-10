# backfabric finalize: ends the installation of a host by deleting its state
# directory. See docs/fleet-shell.md.

usage_finalize() {
  cat <<'EOF'
Usage: backfabric finalize <host>

Run inside the fleet dev shell, from the root of the private repository,
after the installed host booted:
  1. Checks that `ssh <host>` works with the host key from the repository.
  2. Asks you to store the LUKS passphrase from the host's state directory in
     your password manager, and to confirm with y.
  3. Deletes the state directory (private keys, passphrase, pinned Rescue
     host key) and lists the files to commit.
EOF
}

cmd_finalize() {
  prog="backfabric finalize"

  case "${1-}" in
  -h | --help)
    usage_finalize
    exit 0
    ;;
  esac
  if [[ $# -ne 1 ]]; then
    usage_finalize >&2
    exit 2
  fi
  host=$1

  check_host_name "$host"
  require_fleet_shell
  require_flake

  state=$(state_dir "$host")
  [[ -d $state ]] || die "no state directory $state; nothing to finalize"
  host_files "$(host_facts "$host" reportPath | jq -r '.reportPath // empty')"

  ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" true ||
    die "cannot log in to $host (ssh $host). It may still be booting or waiting for the passphrase (backfabric unlock $host); wait and run backfabric finalize $host again."
  echo "Logged in to $host with its pinned host key."

  echo
  if [[ -f $state/luks ]]; then
    echo "The LUKS passphrase of $host is in $state/luks."
    echo "It is needed after every reboot (backfabric unlock $host reads it from stdin)."
    read -r -p "Stored it in your password manager? Deletes $state. [y/N] " answer
  else
    read -r -p "Delete $state? [y/N] " answer
  fi
  [[ $answer == [yY] ]] || die "aborted; $state is kept"
  rm -rf "$state"
  echo "Deleted $state."

  cat <<EOF

Commit what is not committed yet:
  $(realpath --relative-to=. "$hostPub")
  $(realpath --relative-to=. "$initrdPub")
  $(realpath --relative-to=. "$report")
  .sops.yaml and the files re-encrypted by backfabric sops add-host
  the host's configuration and its entry in flake.nix
EOF
}
