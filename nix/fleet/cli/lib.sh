# Helpers shared by the subcommands of backfabric, see nix/fleet/cli/default.nix.
# Run by writeShellApplication (bash, errexit, nounset, pipefail).

# The command in messages, e.g. "backfabric install"; set by each subcommand.
prog=backfabric

die() {
  echo "$prog: $*" >&2
  exit 1
}

# The commands run from the root of the private repository.
require_flake() {
  [[ -f flake.nix ]] || die "no flake.nix in $PWD; run from the root of the private repository"
}

# The name ends up in a YAML anchor, a file name, and a regular expression.
check_host_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] ||
    die "host name $1: only letters, digits, - and _ are supported"
  [[ $1 != common ]] || die "host name common: secrets/common.yaml is the file of all hosts"
  [[ $1 != admin ]] || die "host name admin: secrets/admin.yaml is the file of the admins only"
}

# Fails if .sops.yaml has admin keys (admin_*) whose type cannot be told from
# the value: the generated rules list them under age or pgp by their value.
check_admin_key_types() {
  local unknown
  unknown=$(yq '.keys[] | select(anchor | test("^admin_")) |
    select(test("^(age1|ssh-)|^[0-9A-Fa-f]{40}$") | not) | anchor' .sops.yaml)
  [[ -z $unknown ]] ||
    die "admin keys of unknown type in .sops.yaml: ${unknown//$'\n'/, }; $1 by hand"
}

# ensure_admin_rule: adds the rule for secrets/admin.yaml to .sops.yaml if it
# is missing: every admin key (admin_*), no host. The file holds what only
# the admins need, e.g. the key of OpenBao's CA; backfabric sops add-host
# never adds a host to it.
ensure_admin_rule() {
  export adminRegex='^secrets/admin\.yaml$'
  [[ $(yq '[.creation_rules[] | select(.path_regex == strenv(adminRegex))] | length' .sops.yaml) == 0 ]] ||
    return 0
  check_admin_key_types "add the rule for secrets/admin.yaml"
  # The new lists first hold the anchor names, which then become aliases.
  yq -i '
    .creation_rules += [{
      "path_regex": strenv(adminRegex),
      "key_groups": [{
        "age": [.keys[] | select(anchor | test("^admin_")) | select(test("^(age1|ssh-)")) | anchor],
        "pgp": [.keys[] | select(anchor | test("^admin_")) | select(test("^[0-9A-Fa-f]{40}$")) | anchor]
      }]
    }] |
    (.creation_rules[-1].key_groups[0][][]) alias |= . |
    del(.creation_rules[-1].key_groups[0][] | select(length == 0))
  ' .sops.yaml
  echo "Added the rule for secrets/admin.yaml (admin keys only) to .sops.yaml."
}

# Fails unless the flake in the current directory has nixosConfigurations.<host>.
require_host() {
  local hosts
  hosts=$(nix eval --json .#nixosConfigurations --apply builtins.attrNames) ||
    die "cannot evaluate nixosConfigurations of $PWD"
  jq -e --arg host "$1" 'index($host) != null' <<<"$hosts" >/dev/null ||
    die "no nixosConfigurations.$1; hosts: $(jq -r 'join(", ")' <<<"$hosts")"
}

# host_facts <host> <attribute>...: prints the given attributes of
# nix/fleet/facts.nix ($factsNix) for nixosConfigurations.<host> as a JSON object.
# The facts work without a facter report; hostPublicKey needs the host's
# public key file. Passed as text: pure evaluation may not import it from its
# path.
host_facts() {
  local host=$1
  shift
  nix eval --json ".#nixosConfigurations.\"$host\"" \
    --apply "system: { inherit (($(<"$factsNix")) system) $*; }"
}

# host_files <reportPath>: sets `report`, the host's nixos-facter report in the
# working tree, and next to it `hostPub` and `initrdPub`, the public key
# files. `reportPath` (hardware.facter.reportPath, from host_facts) is a path
# in the flake source, which is the git repository copied to the Nix store;
# it is mapped back to the working tree.
host_files() {
  local repo
  repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "$PWD is not in a git repository"
  [[ -n $1 ]] ||
    die "hardware.facter.reportPath of $host is not set; set it to e.g. ./facter.json next to the host's configuration"
  [[ $1 =~ ^/nix/store/[^/]+/(.+)$ ]] ||
    die "hardware.facter.reportPath of $host is not a file in the repository: $1"
  report=$repo/${BASH_REMATCH[1]}
  hostPub=$(dirname "$report")/ssh_host_ed25519_key.pub
  initrdPub=$(dirname "$report")/initrd_ssh_host_ed25519_key.pub
}

# The state directory of a host between `backfabric keygen` and
# `backfabric finalize`, outside the repository:
#   extra-files/  for nixos-anywhere --extra-files: the private host key
#                 (etc/ssh/ssh_host_ed25519_key) and the initrd host key
#                 (at backfabric.access.initrdSsh.hostKey), from keygen;
#   luks          the LUKS passphrase, from keygen;
#   known_hosts   the pinned host key of the Rescue system, which the kexec
#                 installer keeps, from probe.
state_dir() {
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/backfabric/$1"
}

# require_fleet_ssh <alias>: fails unless ssh resolves <alias> through the
# fleet dev shell's config: the shell exports PROJECT_SSH_CONFIG, and
# ~/.ssh/config includes it (`Include ${PROJECT_SSH_CONFIG}` as its first
# line; see docs/fleet-shell.md).
require_fleet_ssh() {
  [[ -n ${PROJECT_SSH_CONFIG-} ]] ||
    die "run inside the fleet dev shell (nix develop in the private repository), which sets PROJECT_SSH_CONFIG"
  local resolved
  resolved=$(ssh -G "$1" 2>/dev/null) || resolved=
  grep -Fqxi "hostkeyalias $1" <<<"$resolved" ||
    die "ssh does not use the fleet config for $1; add 'Include \${PROJECT_SSH_CONFIG}' as the first line of ~/.ssh/config (docs/fleet-shell.md)"
}

# use_pinned_ssh <known_hosts>: puts an ssh first in PATH, for this command
# and the nixos-anywhere, nix and ssh-copy-id it runs, that only accepts the
# host keys in <known_hosts>. nixos-anywhere passes `-o
# StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` to ssh, and ssh
# uses the first value of an option, so its `--ssh-option` cannot enable
# checking; this ssh puts the pinned options first.
use_pinned_ssh() {
  local dir
  dir=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: $dir is local
  trap "rm -rf '$dir'" EXIT
  printf '#!%s\nexec %q -o UserKnownHostsFile=%q -o GlobalKnownHostsFile=none -o StrictHostKeyChecking=yes "$@"\n' \
    "$BASH" "$(command -v ssh)" "$1" >"$dir/ssh"
  chmod +x "$dir/ssh"
  PATH=$dir:$PATH
}

# check_uplink <host> <address> <macAddress>: on the server in the NixOS
# installer (with use_pinned_ssh), checks that an interface has the
# configured MAC address and that its kernel module is in the host's initrd,
# which needs it for SSH. nixos-facter reports do not contain MAC addresses,
# so this cannot be an evaluation-time assertion.
check_uplink() {
  local host=$1 address=$2 mac=${3,,} links ifname module modules
  links=$(ssh -o ConnectTimeout=10 "root@$address" ip -j link) ||
    die "cannot list the network interfaces of $address"
  echo "Network interfaces of the server (ip link):"
  jq -r '.[] | select(.link_type == "ether") | "  \(.ifname)  \(.permaddr // .address)"' <<<"$links"
  ifname=$(jq -r --arg mac "$mac" '
    first(.[] | select([.address, .permaddr] | map(ascii_downcase?) | index($mac)) | .ifname) // empty
  ' <<<"$links")
  [[ -n $ifname ]] ||
    die "backfabric.network.macAddress of $host ($mac) is on no interface of the server; set it to the uplink's MAC above"
  # shellcheck disable=SC2029 # expand locally: the interface name
  module=$(ssh -o ConnectTimeout=10 "root@$address" \
    "readlink /sys/class/net/$(printf %q "$ifname")/device/driver/module") || true
  module=${module##*/}
  [[ -n $module ]] ||
    die "cannot determine the kernel module of the uplink $ifname (no /sys/class/net/$ifname/device/driver/module)"
  modules=$(nix eval --json ".#nixosConfigurations.\"$host\".config.boot.initrd" \
    --apply 'initrd: initrd.kernelModules ++ initrd.availableKernelModules') ||
    die "cannot evaluate the initrd kernel modules of $host"
  jq -e --arg module "${module//-/_}" 'map(gsub("-"; "_")) | index($module) != null' <<<"$modules" >/dev/null ||
    die "the driver of the uplink $ifname ($mac), kernel module $module, is not in the initrd of $host, so the initrd would have no network for unlocking; the facter report should list it as a driver module of a network controller"
  echo "Uplink: $ifname ($mac), kernel module $module, which is in the initrd."
}
