# Adds a host of the private repository to its .sops.yaml. Run by
# writeShellApplication (bash, errexit, nounset, pipefail). See
# docs/secrets.md.

usage() {
  cat <<'EOF'
Usage: backfabric-sops-add-host [--replace] <host>

Adds nixosConfigurations.<host> of the flake in the current directory, the
root of the private repository, to its .sops.yaml (created by
backfabric-sops-init):
  - the key host_<host>: ssh-to-age of backfabric.access.hostKey.publicKey;
  - a rule for secrets/<host>.yaml: every admin key (admin_*) and the host;
  - the host in the rule for secrets/common.yaml.
Then runs `sops updatekeys` on secrets/common.yaml and secrets/<host>.yaml if
they exist (needs an admin key).

Does nothing if the host is already there with the same key. Refuses if it is
there with another key, unless --replace is given: then the key host_<host> is
replaced (after a host key rotation or a reinstall).
EOF
}

die() {
  echo "backfabric-sops-add-host: $*" >&2
  exit 1
}

replace=n
host=
for arg; do
  case $arg in
  -h | --help)
    usage
    exit 0
    ;;
  --replace)
    replace=y
    ;;
  -*)
    usage >&2
    exit 2
    ;;
  *)
    [[ -z $host ]] || {
      usage >&2
      exit 2
    }
    host=$arg
    ;;
  esac
done
[[ -n $host ]] || {
  usage >&2
  exit 2
}

# The name ends up in a YAML anchor, a file name, and a regular expression.
[[ $host =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] ||
  die "host name $host: only letters, digits, - and _ are supported"
[[ $host != common ]] || die "host name common: secrets/common.yaml is the file of all hosts"

[[ -f flake.nix ]] || die "no flake.nix in $PWD; run from the root of the private repository"
[[ -f .sops.yaml ]] || die "no .sops.yaml in $PWD; create it with backfabric-sops-init"

# --- Recipient ----------------------------------------------------------------

hosts=$(nix eval --json .#nixosConfigurations --apply builtins.attrNames) ||
  die "cannot evaluate nixosConfigurations of $PWD"
jq -e --arg host "$host" 'index($host) != null' <<<"$hosts" >/dev/null ||
  die "no nixosConfigurations.$host; hosts: $(jq -r 'join(", ")' <<<"$hosts")"

# fleet/facts.nix ($factsNix, set by fleet/sops-add-host.nix) works without a
# facter report. Passed as text: pure evaluation may not import it from its
# path.
publicKey=$(nix eval --raw ".#nixosConfigurations.\"$host\"" \
  --apply "system: (($(<"$factsNix")) system).hostPublicKey") ||
  die "cannot evaluate backfabric.access.hostKey.publicKey of $host"
recipient=$(ssh-to-age <<<"$publicKey")

# --- .sops.yaml ---------------------------------------------------------------

# Read by yq with strenv.
export anchor=host_$host recipient
export commonRegex='^secrets/common\.yaml$' hostRegex="^secrets/$host\\.yaml\$"

current=$(yq '.keys[] | select(anchor == strenv(anchor))' .sops.yaml)

if [[ $current == "$recipient" ]]; then
  echo "$host is already in .sops.yaml with $recipient; nothing to do."
  exit 0
elif [[ -n $current && $replace == n ]]; then
  die "$host is in .sops.yaml with another key ($current, now $recipient). If its host key was rotated or it was reinstalled, run again with --replace."
elif [[ -n $current ]]; then
  # Aliases (*host_<host>) refer to the anchored node, so the rules follow.
  yq -i '(.keys[] | select(anchor == strenv(anchor))) |= strenv(recipient)' .sops.yaml
  echo "Replaced the key of $host in .sops.yaml: $recipient (was $current)."
else
  [[ $(yq '[.creation_rules[] | select(.path_regex == strenv(commonRegex))] | length' .sops.yaml) == 1 ]] ||
    die ".sops.yaml has no rule with path_regex $commonRegex"
  [[ $(yq '[.creation_rules[] | select(.path_regex == strenv(hostRegex))] | length' .sops.yaml) == 0 ]] ||
    die ".sops.yaml has a rule with path_regex $hostRegex but no key $anchor; fix it by hand"
  # The host rule lists the admin keys by type, which is told by the value.
  unknown=$(yq '.keys[] | select(anchor | test("^admin_")) |
    select(test("^(age1|ssh-)|^[0-9A-Fa-f]{40}$") | not) | anchor' .sops.yaml)
  [[ -z $unknown ]] ||
    die "admin keys of unknown type in .sops.yaml: ${unknown//$'\n'/, }; add $host by hand"

  # The new lists first hold the anchor names, which then become aliases.
  yq -i '
    .keys += [strenv(recipient)] |
    .keys[-1] anchor = strenv(anchor) |
    .creation_rules += [{
      "path_regex": strenv(hostRegex),
      "key_groups": [{
        "age": [.keys[] | select(anchor | test("^admin_")) | select(test("^(age1|ssh-)")) | anchor] + [strenv(anchor)],
        "pgp": [.keys[] | select(anchor | test("^admin_")) | select(test("^[0-9A-Fa-f]{40}$")) | anchor]
      }]
    }] |
    (.creation_rules[-1].key_groups[0][][]) alias |= . |
    del(.creation_rules[-1].key_groups[0][] | select(length == 0)) |
    (.creation_rules[] | select(.path_regex == strenv(commonRegex)) | .key_groups[0].age) += [strenv(anchor)] |
    (.creation_rules[] | select(.path_regex == strenv(commonRegex)) | .key_groups[0].age[-1]) alias = strenv(anchor)
  ' .sops.yaml
  echo "Added $host to .sops.yaml: $recipient."
fi

# --- Encrypted files ----------------------------------------------------------

# A rerun finds the host in .sops.yaml and does nothing, so say what is left.
files=()
for file in secrets/common.yaml "secrets/$host.yaml"; do
  if [[ -e $file ]]; then
    files+=("$file")
  fi
done
for file in "${files[@]}"; do
  sops updatekeys -y "$file" ||
    die ".sops.yaml is updated, but sops updatekeys failed (it needs an admin key); run it again for ${files[*]}"
done
