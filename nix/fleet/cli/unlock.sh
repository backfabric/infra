# backfabric unlock: sends the LUKS passphrase to a host waiting in the
# initrd. See docs/initrd-unlock.md.

usage_unlock() {
  cat <<'EOF'
Usage: backfabric unlock <host>

Run inside the fleet dev shell, with `Include ${PROJECT_SSH_CONFIG}` as the
first line of ~/.ssh/config. Sends the LUKS passphrase of <host> to its
initrd over `ssh <host>-initrd`, where systemd-tty-ask-password-agent answers
the pending passphrase requests of systemd-cryptsetup. The passphrase comes
from the host's state directory (between backfabric keygen and finalize),
else from stdin: typed at a prompt, or piped, e.g.
  op read op://vault/node1/luks | backfabric unlock node1
Does not wait for the boot to finish. Use it after every reboot.
EOF
}

cmd_unlock() {
  prog="backfabric unlock"

  case "${1-}" in
  -h | --help)
    usage_unlock
    exit 0
    ;;
  esac
  if [[ $# -ne 1 ]]; then
    usage_unlock >&2
    exit 2
  fi
  host=$1

  check_host_name "$host"
  require_fleet_ssh "$host-initrd"

  luks=$(state_dir "$host")/luks
  if [[ -f $luks ]]; then
    echo "Passphrase from $luks."
    passphrase=$(<"$luks")
  elif [[ -t 0 ]]; then
    read -r -s -p "LUKS passphrase of $host: " passphrase
    echo
  else
    IFS= read -r passphrase || [[ -n $passphrase ]] || die "no passphrase on stdin"
  fi
  [[ -n $passphrase ]] || die "empty passphrase"
  [[ $passphrase != *$'\n'* ]] || die "the passphrase has more than one line"

  # Runs in the initrd's root shell (bash). The passphrase arrives on stdin,
  # not on a command line. With SYSTEMD_ASK_PASSWORD_AGENT_PASSWORD set, the
  # agent sends it to every pending request instead of asking on a terminal;
  # systemd-cryptsetup caches it in the kernel keyring for disks that ask
  # later.
  # shellcheck disable=SC2016 # expanded in the initrd
  remote='
    shopt -s nullglob
    requests=(/run/systemd/ask-password/ask.*)
    if [[ ${#requests[@]} -eq 0 ]]; then
      echo "no pending passphrase request" >&2
      exit 3
    fi
    IFS= read -r passphrase
    SYSTEMD_ASK_PASSWORD_AGENT_PASSWORD=$passphrase systemd-tty-ask-password-agent --query
  '
  status=0
  printf '%s\n' "$passphrase" | ssh -T -o ConnectTimeout=10 "$host-initrd" "$remote" || status=$?
  unset passphrase
  case $status in
  0) ;;
  3)
    die "the initrd of $host has no pending passphrase request: it is unlocked already, or still starting (run backfabric unlock $host again)"
    ;;
  255)
    die "cannot connect to $host-initrd: the host may still be booting (run backfabric unlock $host again), or already be unlocked (ssh $host)"
    ;;
  *)
    die "sending the passphrase failed (exit status $status)"
    ;;
  esac

  cat <<EOF
Sent the passphrase to $host. It continues to boot; if the passphrase was
wrong, the initrd asks again: run backfabric unlock $host again.
EOF
  if [[ -f $luks ]]; then
    echo "Next, once it is up: backfabric finalize $host"
  fi
}
