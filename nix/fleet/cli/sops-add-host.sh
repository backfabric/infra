# backfabric sops add-host: adds a host of the private repository to its
# .sops.yaml. See docs/secrets.md.

usage_sops_add_host() {
  cat <<'EOF'
Usage: backfabric sops add-host [--replace] <host>

Adds nixosConfigurations.<host> of the flake in the current directory, the
root of the private repository, to its .sops.yaml (created by
backfabric sops init):
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

cmd_sops_add_host() {
  prog="backfabric sops add-host"

  replace=n
  host=
  for arg; do
    case $arg in
    -h | --help)
      usage_sops_add_host
      exit 0
      ;;
    --replace)
      replace=y
      ;;
    -*)
      usage_sops_add_host >&2
      exit 2
      ;;
    *)
      [[ -z $host ]] || {
        usage_sops_add_host >&2
        exit 2
      }
      host=$arg
      ;;
    esac
  done
  [[ -n $host ]] || {
    usage_sops_add_host >&2
    exit 2
  }

  check_host_name "$host"
  require_flake
  [[ -f .sops.yaml ]] || die "no .sops.yaml in $PWD; create it with backfabric sops init"

  # --- Recipient --------------------------------------------------------------

  require_host "$host"
  publicKey=$(host_facts "$host" hostPublicKey | jq -r .hostPublicKey) ||
    die "cannot evaluate backfabric.access.hostKey.publicKey of $host"
  recipient=$(ssh-to-age <<<"$publicKey")

  # --- .sops.yaml -------------------------------------------------------------

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

  # --- Encrypted files --------------------------------------------------------

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
}
