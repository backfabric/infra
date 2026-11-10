# backfabric probe: boots a server from the Hetzner Rescue system into the
# NixOS installer and generates its nixos-facter report. See
# docs/fleet-shell.md.

usage_probe() {
  cat <<'EOF'
Usage: backfabric probe <host>

For nixosConfigurations.<host> of the flake in the current directory (the
root of the private repository), on a server booted into the Hetzner Rescue
system (or already in the NixOS installer from an earlier probe):
  1. Pins the server's SSH host key: on the first run, connects to
     root@<address> port 22, shows the key's fingerprints for comparison with
     the Hetzner Robot, and stores it in the host's state directory
     (known_hosts). The NixOS installer keeps the Rescue host keys.
  2. Runs nixos-anywhere up to the kexec into the NixOS installer and writes
     the nixos-facter report to hardware.facter.reportPath.
  3. Prints a hardware summary from the report.
  4. Evaluates the host's configuration, which checks the network driver and
     the disks against the report.
  5. Checks that the configured MAC address is on the server and that its
     driver is in the initrd.
Nothing is written to the disks. Re-run it after changing the configuration.
EOF
}

# hardware_summary <report>: what a host configuration needs from the report.
hardware_summary() {
  jq -r '
    def names: (. // []) | join(", ");
    def disksize:
      first((.resources // [])[] | select(.type == "size" and .unit == "sectors")
        | .value_1 * .value_2 / 1e9 | floor | "\(.) GB") // "size unknown";
    "System: \(.system // "unknown"), virtualisation: \(.virtualisation // "unknown")",
    "Boot:   \(if .uefi == null then "not in the report"
              elif .uefi.supported then "UEFI" else "legacy BIOS" end)",
    "CPU:    \(.hardware.cpu[0].model_name // .smbios.processor[0].version // "unknown")"
      + (.hardware.cpu[0] | if . then " (\(.cores) cores, \(.units) threads)" else "" end),
    "RAM:    \([.hardware.memory[]?.resources[]? | select(.type == "phys_mem") | .range] | add
              | if . then "\(. / 1073741824 | floor) GiB" else "unknown" end)",
    "",
    "Network controllers:",
    (.hardware.network_controller[]?
      | "  \(.model // "unknown model"): driver modules: \(.driver_modules | names), interface: \(.unix_device_names | names)"),
    "",
    "Disks (backfabric.disks.devices takes /dev/disk/by-id/ names of whole disks):",
    (.hardware.disk[]?
      | "  \(.model // "unknown model"), \(disksize):",
        ((.unix_device_names // [])[] | select(startswith("/dev/disk/by-id/")) | "    \(.)"))
  ' "$1"
}

cmd_probe() {
  prog="backfabric probe"

  case "${1-}" in
  -h | --help)
    usage_probe
    exit 0
    ;;
  esac
  if [[ $# -ne 1 ]]; then
    usage_probe >&2
    exit 2
  fi
  host=$1

  check_host_name "$host"
  require_flake
  command -v ssh >/dev/null || die "no ssh in PATH"
  command -v ssh-keygen >/dev/null || die "no ssh-keygen in PATH"
  require_host "$host"

  # Facts that also work without the report and the public key files.
  facts=$(host_facts "$host" address macAddress reportPath)
  address=$(jq -r .address <<<"$facts")
  macAddress=$(jq -r .macAddress <<<"$facts")
  host_files "$(jq -r '.reportPath // empty' <<<"$facts")"

  # --- 1. Host key of the Rescue system ---------------------------------------

  state=$(state_dir "$host")
  install -d -m 700 "$state"
  knownHosts=$state/known_hosts
  if [[ -e $knownHosts ]]; then
    echo "Pinned host key of $address ($knownHosts):"
    ssh-keygen -l -f "$knownHosts"
  else
    rm -f "$knownHosts.new"
    echo "Connecting to the Hetzner Rescue system at root@$address (port 22) ..."
    ssh -p 22 \
      -o UserKnownHostsFile="$knownHosts.new" \
      -o GlobalKnownHostsFile=none \
      -o StrictHostKeyChecking=accept-new \
      "root@$address" true || die "cannot connect to root@$address; is the server in the Rescue system?"
    echo "Rescue host key (compare with the fingerprints shown in the Hetzner Robot):"
    ssh-keygen -l -f "$knownHosts.new"
    ssh-keygen -l -E md5 -f "$knownHosts.new"
    read -r -p "Do they match? [y/N] " answer
    [[ $answer == [yY] ]] || {
      rm -f "$knownHosts.new"
      die "aborted"
    }
    mv "$knownHosts.new" "$knownHosts"
  fi
  use_pinned_ssh "$knownHosts"

  # --- 2. Installer and report ------------------------------------------------

  # Only the kexec phase; nixos-anywhere skips it on a server that already
  # runs the NixOS installer. Neither building on the server nor its
  # substituters need the configuration: nothing is evaluated.
  nixos-anywhere \
    --flake ".#$host" \
    --phases kexec \
    --generate-hardware-config nixos-facter "$report" \
    --build-on remote \
    --no-use-machine-substituters \
    "root@$address" ||
    die "nixos-anywhere failed; fix the cause and run backfabric probe $host again. If the server rejects the pinned host key after the Rescue system was activated again, delete $knownHosts first."

  # --- 3. Summary -------------------------------------------------------------

  echo
  echo "Hardware of $host ($(realpath --relative-to=. "$report")):"
  echo
  hardware_summary "$report"
  echo

  # --- 4. Configuration -------------------------------------------------------

  echo "Evaluating nixosConfigurations.$host ..."
  if ! nix eval --raw ".#nixosConfigurations.\"$host\".config.system.build.toplevel.drvPath" >/dev/null; then
    echo >&2
    die "the configuration of $host does not evaluate (error above). Fill in the values from the summary (backfabric.disks.devices, backfabric.network.macAddress, ...) and run backfabric probe $host again."
  fi
  echo

  # --- 5. Uplink --------------------------------------------------------------

  check_uplink "$host" "$address" "$macAddress"

  cat <<EOF

$host evaluates and matches the server. Next:
  1. Review the report and commit it, with the host's other new files
     (configuration, .pub files, .sops.yaml), e.g.:
       git add $(realpath --relative-to=. "$report") && git commit
  2. backfabric install $host   (ERASES ALL DISKS)
EOF
}
