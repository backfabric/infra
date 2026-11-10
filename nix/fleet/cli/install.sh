# backfabric install: installs a host of the private repository on a server
# in the NixOS installer (after backfabric probe) with nixos-anywhere. See
# docs/fleet-shell.md.

usage_install() {
  cat <<'EOF'
Usage: backfabric install <host>

Installs nixosConfigurations.<host> of the flake in the current directory (the
root of the private repository) on a server that `backfabric probe <host>`
booted into the NixOS installer. ERASES ALL DISKS of the server.

Requires the host's state directory from `backfabric keygen <host>` with the
pinned host key from probe, the host's nixos-facter report committed to git,
and, if .sops.yaml exists, the host in it (`backfabric sops add-host <host>`).

Steps:
  1. Evaluate the configuration.
  2. Check that the server runs the NixOS installer, that the configured MAC
     address is on it, and that its driver is in the initrd.
  3. Run nixos-anywhere: partition and encrypt the disks (disko), install
     NixOS (built on the server) with the host keys from the state directory,
     and reboot.
The host then waits for the LUKS passphrase: backfabric unlock <host>.
EOF
}

cmd_install() {
  prog="backfabric install"

  case "${1-}" in
  -h | --help)
    usage_install
    exit 0
    ;;
  esac
  if [[ $# -ne 1 ]]; then
    usage_install >&2
    exit 2
  fi
  host=$1

  check_host_name "$host"
  require_flake
  command -v ssh >/dev/null || die "no ssh in PATH"
  command -v ssh-keygen >/dev/null || die "no ssh-keygen in PATH"
  require_host "$host"

  facts=$(host_facts "$host" address macAddress initrdHostKey reportPath)
  address=$(jq -r .address <<<"$facts")
  macAddress=$(jq -r .macAddress <<<"$facts")
  initrdHostKey=$(jq -r .initrdHostKey <<<"$facts")
  host_files "$(jq -r '.reportPath // empty' <<<"$facts")"

  # --- Prerequisites ----------------------------------------------------------

  state=$(state_dir "$host")
  extraFiles=$state/extra-files
  [[ -d $extraFiles && -f $state/luks ]] ||
    die "no keys of $host in $state; run backfabric keygen $host first"
  [[ -f $state/known_hosts ]] ||
    die "no pinned host key of the server in $state; run backfabric probe $host first"

  # The keys to install must be the ones the repository (and .sops.yaml) knows.
  for pair in "etc/ssh/ssh_host_ed25519_key:$hostPub" "${initrdHostKey#/}:$initrdPub"; do
    private=$extraFiles/${pair%%:*}
    public=${pair#*:}
    [[ -f $public ]] || die "$public is missing; it is written by backfabric keygen $host"
    [[ $(ssh-keygen -y -f "$private" | cut -d' ' -f1-2) == $(cut -d' ' -f1-2 "$public") ]] ||
      die "$private does not match $public; to start over, delete $state and both .pub files and run backfabric keygen $host"
  done

  rel=$(realpath --relative-to="$(git rev-parse --show-toplevel)" "$report")
  if ! [[ -f $report ]] || ! git cat-file -e "HEAD:$rel" 2>/dev/null || ! git diff --quiet HEAD -- "$report"; then
    die "$rel is missing, not committed, or changed; run backfabric probe $host, review the report, and commit it"
  fi

  if [[ -f .sops.yaml ]]; then
    publicKey=$(host_facts "$host" hostPublicKey | jq -r .hostPublicKey) ||
      die "cannot evaluate backfabric.access.hostKey.publicKey of $host"
    recipient=$(ssh-to-age <<<"$publicKey")
    current=$(anchor=host_$host yq '.keys[] | select(anchor == strenv(anchor))' .sops.yaml)
    [[ -n $current ]] || die "$host is not in .sops.yaml; run backfabric sops add-host $host"
    [[ $current == "$recipient" ]] ||
      die "$host is in .sops.yaml with another key; run backfabric sops add-host --replace $host"
  fi

  # --- 1. Configuration -------------------------------------------------------

  echo "Evaluating nixosConfigurations.$host ..."
  nix eval --raw ".#nixosConfigurations.\"$host\".config.system.build.toplevel.drvPath" >/dev/null ||
    die "the configuration of $host does not evaluate (error above); fix it (backfabric probe $host shows the hardware)"

  # --- 2. Server --------------------------------------------------------------

  use_pinned_ssh "$state/known_hosts"
  # The same test as nixos-anywhere's: an installer is NixOS with
  # VARIANT_ID=installer. Without the kexec phase, nixos-anywhere would not
  # check it.
  status=0
  ssh -o ConnectTimeout=10 "root@$address" \
    "grep -Eq '^VARIANT_ID=\"?installer\"?\$' /etc/os-release" || status=$?
  case $status in
  0) ;;
  255)
    die "cannot connect to root@$address with the pinned host key. If the server left the NixOS installer (rebooted), activate the Rescue system in the Robot, reset the server, and run backfabric probe $host again (after deleting $state/known_hosts if the Rescue host key changed)."
    ;;
  *)
    die "root@$address does not run the NixOS installer. Activate the Rescue system in the Robot, reset the server, and run backfabric probe $host again."
    ;;
  esac
  check_uplink "$host" "$address" "$macAddress"

  # --- 3. Install -------------------------------------------------------------

  # The disko phase copies the passphrase to /tmp/disk-encryption.key on the
  # server, where the disks' LUKS settings read it (nix/modules/disks.nix).
  nixos-anywhere \
    --flake ".#$host" \
    --phases disko,install,reboot \
    --build-on remote \
    --extra-files "$extraFiles" \
    --disk-encryption-keys /tmp/disk-encryption.key "$state/luks" \
    "root@$address" ||
    die "nixos-anywhere failed; fix the cause and run backfabric install $host again (it starts over with the disks)"

  cat <<EOF

Installed $host; it reboots and waits for the LUKS passphrase in the initrd.
Next, once it is up, inside the fleet dev shell (re-enter it if it was started
before the host's .pub files existed):
  backfabric unlock $host
EOF
}
