# Helpers shared by the subcommands of backfabric, see fleet/cli/default.nix.
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
# fleet/facts.nix ($factsNix) for nixosConfigurations.<host> as a JSON object.
# The facts work without a facter report; hostPublicKey needs the host's
# public key file. Passed as text: pure evaluation may not import it from its
# path.
host_facts() {
  local host=$1
  shift
  nix eval --json ".#nixosConfigurations.\"$host\"" \
    --apply "system: { inherit (($(<"$factsNix")) system) $*; }"
}
