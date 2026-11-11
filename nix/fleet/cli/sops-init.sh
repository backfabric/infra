# backfabric sops init: creates the .sops.yaml of the private repository. See
# docs/secrets.md.

usage_sops_init() {
  cat <<'EOF'
Usage: backfabric sops init (--age <recipient> | --pgp <fingerprint>)...

Creates .sops.yaml in the current directory, the root of the private
repository, with the given admin keys (in order: admin_0, admin_1, ...), a
rule for secrets/common.yaml, and a rule for secrets/admin.yaml (admin keys
only, never hosts). Both options may be repeated and mixed; at least
one key is required. Refuses if .sops.yaml exists. Hosts are added with
backfabric sops add-host.

  --age <recipient>     age recipient (age1...)
  --pgp <fingerprint>   PGP key fingerprint (40 hex digits, no spaces)
EOF
}

cmd_sops_init() {
  prog="backfabric sops init"

  # Type and value of each admin key, in command line order.
  types=()
  keys=()
  while [[ $# -gt 0 ]]; do
    case $1 in
    -h | --help)
      usage_sops_init
      exit 0
      ;;
    --age | --pgp)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case $1 in
      --age)
        [[ $2 =~ ^age1[0-9a-z]+$ ]] || die "--age: not an age recipient (age1...): $2"
        ;;
      --pgp)
        [[ $2 =~ ^[0-9A-Fa-f]{40}$ ]] ||
          die "--pgp: not a PGP fingerprint (40 hex digits, no spaces): $2"
        ;;
      esac
      types+=("${1#--}")
      keys+=("$2")
      shift 2
      ;;
    *)
      usage_sops_init >&2
      exit 2
      ;;
    esac
  done
  [[ ${#keys[@]} -gt 0 ]] || {
    usage_sops_init >&2
    exit 2
  }

  require_flake
  [[ ! -e .sops.yaml ]] || die ".sops.yaml exists; edit it by hand or with backfabric sops add-host"

  {
    cat <<'EOF'
# sops configuration, created by backfabric sops init. backfabric sops add-host
# maintains the hosts: the keys host_<host>, the rules for secrets/<host>.yaml,
# and the hosts in the rule for secrets/common.yaml. secrets/admin.yaml is for
# the admins only: no host belongs in its rule. The admin keys (admin_<n>)
# may be edited by hand; a new admin key belongs in every rule.
keys:
EOF
    for i in "${!keys[@]}"; do
      # Quoted: a fingerprint of digits only would otherwise be a number.
      printf '  - &admin_%d "%s"\n' "$i" "${keys[i]}"
    done
    cat <<'EOF'
creation_rules:
  - path_regex: ^secrets/common\.yaml$
    key_groups:
EOF
    separator=-
    for type in age pgp; do
      [[ " ${types[*]} " == *" $type "* ]] || continue
      printf '      %s %s:\n' "$separator" "$type"
      separator=" "
      for i in "${!keys[@]}"; do
        [[ ${types[i]} == "$type" ]] || continue
        printf '          - *admin_%d\n' "$i"
      done
    done
  } >.sops.yaml
  ensure_admin_rule >/dev/null

  echo "Created .sops.yaml with ${#keys[@]} admin key(s). Add hosts with backfabric sops add-host <host>."
}
