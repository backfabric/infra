# backfabric keygen: generates the keys and the LUKS passphrase of a host
# before its installation, and the cluster-wide secrets that are missing.
# See docs/fleet-shell.md.

usage_keygen() {
  cat <<'EOF'
Usage: backfabric keygen [<host>]

Generates, locally, for nixosConfigurations.<host> of the flake in the
current directory (the root of the private repository):
  - the SSH ed25519 host key and the initrd host key;
  - a random LUKS passphrase for the disks.
The private keys and the passphrase go into the host's state directory,
~/.local/state/backfabric/<host>/ (under $XDG_STATE_HOME if set; mode 700),
until `backfabric finalize <host>` deletes it. The public keys are written
next to the host's nixos-facter report (hardware.facter.reportPath):
ssh_host_ed25519_key.pub and initrd_ssh_host_ed25519_key.pub.
Refuses if the host already has keys in its state directory or .pub files.

With or without <host> (then before the host's keys), it also makes sure
that secrets/common.yaml, the sops file every host can read, has the
cluster-wide secrets:
  - k3s-token: the k3s cluster token (32 random bytes, hex);
  - openbao-seal-key: OpenBao's static seal key (32 random bytes, hex);
  - openbao-ca-key, openbao-ca-cert: the CA of OpenBao's TLS certificate
    (ECDSA P-256, 10 years);
  - openbao-tls-key, openbao-tls-cert: OpenBao's TLS key and certificate
    (ECDSA P-256, 3 years) for openbao.openbao.svc,
    openbao.openbao.svc.cluster.local and 127.0.0.1, signed by that CA.
Generates only the missing ones and never changes an existing value; with
the CA present and both openbao-tls-* missing, it issues a new server
certificate (rotation, docs/openbao.md). Creates the file if it does not
exist, encrypted as .sops.yaml says; adding to an existing file needs an
admin key. Skipped without .sops.yaml.

Without <host>, only the cluster-wide secrets: for hosts that are already
installed.
EOF
}

# The random cluster-wide secrets in secrets/common.yaml. Each is generated
# by keygen if missing, and must never change afterwards (the k3s token is
# needed to restore an etcd snapshot, the seal key to unseal OpenBao).
clusterSecrets=(k3s-token openbao-seal-key)

# OpenBao's TLS material, also in secrets/common.yaml.
tlsCaSecrets=(openbao-ca-key openbao-ca-cert)
tlsServerSecrets=(openbao-tls-key openbao-tls-cert)
# The name pods use (nix/modules/openbao.nix), and the loopback address for
# clients on the host.
tlsNames=DNS:openbao.openbao.svc,DNS:openbao.openbao.svc.cluster.local,IP:127.0.0.1
tlsCaDays=3650
tlsServerDays=1095

# ensure_cluster_secrets: adds the missing cluster-wide secrets to
# secrets/common.yaml, creating the file if needed.
ensure_cluster_secrets() {
  local file=secrets/common.yaml name missing=() present=() caKey caCert
  local -A values=()
  if [[ ! -f .sops.yaml ]]; then
    echo "No .sops.yaml; once it exists (backfabric sops init), run backfabric keygen to create $file with the cluster-wide secrets."
    return
  fi

  # Only the values of a sops file are encrypted, so the names can be read
  # without a key.
  for name in "${clusterSecrets[@]}" "${tlsCaSecrets[@]}" "${tlsServerSecrets[@]}"; do
    if [[ ! -f $file ]] || [[ $(name=$name yq 'has(strenv(name))' "$file") != true ]]; then
      missing+=("$name")
    else
      present+=("$name")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "$file has every cluster-wide secret; left unchanged."
    return
  fi

  # The values stay in this process's memory: they go to openssl and sops
  # through pipes (printf is a builtin), never as arguments or into an
  # unencrypted file.
  for name in "${clusterSecrets[@]}"; do
    if ! in_list "$name" "${present[@]}"; then
      values[$name]=$(random_hex 32)
    fi
  done

  case "$(tls_state "${present[@]}")" in
  complete) ;;
  none)
    caKey=$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256)
    caCert=$(openssl req -new -x509 -key <(printf '%s\n' "$caKey") \
      -subj "/CN=OpenBao CA" -days "$tlsCaDays" \
      -addext basicConstraints=critical,CA:TRUE,pathlen:0 \
      -addext keyUsage=critical,keyCertSign,cRLSign)
    values["openbao-ca-key"]=$caKey$'\n'
    values["openbao-ca-cert"]=$caCert$'\n'
    issue_tls_cert "$caKey" "$caCert"
    ;;
  ca)
    # Rotation: a new server certificate from the existing CA.
    caKey=$(sops decrypt --extract '["openbao-ca-key"]' "$file") ||
      die "cannot read openbao-ca-key from $file; sops needs an admin key (docs/secrets.md)"
    caCert=$(sops decrypt --extract '["openbao-ca-cert"]' "$file") ||
      die "cannot read openbao-ca-cert from $file; sops needs an admin key (docs/secrets.md)"
    issue_tls_cert "$caKey" "$caCert"
    ;;
  *)
    die "$file has only some of OpenBao's TLS secrets (${tlsCaSecrets[*]} ${tlsServerSecrets[*]}). To issue a new server certificate, remove both ${tlsServerSecrets[*]} (sops unset $file '[\"<name>\"]'); see docs/openbao.md"
    ;;
  esac
  unset caKey

  if [[ ! -f $file ]]; then
    mkdir -p "$(dirname "$file")"
    # Encrypting needs only the public keys in .sops.yaml. Each value as a
    # JSON string, which YAML reads as well (the PEM values span lines).
    for name in "${missing[@]}"; do
      printf '%s: %s\n' "$name" "$(printf '%s' "${values[$name]}" | jq -Rs .)"
    done | sops encrypt --filename-override "$file" >"$file.new" || {
      rm -f "$file.new"
      die "cannot create $file with sops (see above); check the rule for $file in .sops.yaml"
    }
    mv "$file.new" "$file"
    # See the public keys below.
    git add --intent-to-add -- "$file"
    echo "Created $file with ${missing[*]}, encrypted for the keys of its rule in .sops.yaml."
  else
    for name in "${missing[@]}"; do
      printf '%s' "${values[$name]}" | jq -Rs . | sops set --value-stdin "$file" "[\"$name\"]" ||
        die "cannot add $name to $file; sops needs an admin key to edit it (docs/secrets.md)"
      echo "Added $name to $file."
    done
  fi
  echo "Commit $file; hosts read it at their next deployment."
}

# in_list <word> <list>...: whether <word> is one of <list>.
in_list() {
  local word=$1 item
  shift
  for item in "$@"; do
    [[ $item != "$word" ]] || return 0
  done
  return 1
}

# tls_state <present names>...: which of OpenBao's TLS secrets exist:
# complete, none, ca (the CA without the server certificate), or partial.
tls_state() {
  local name ca=0 server=0
  for name in "${tlsCaSecrets[@]}"; do
    ! in_list "$name" "$@" || ca=$((ca + 1))
  done
  for name in "${tlsServerSecrets[@]}"; do
    ! in_list "$name" "$@" || server=$((server + 1))
  done
  case "$ca$server" in
  22) echo complete ;;
  00) echo none ;;
  20) echo ca ;;
  *) echo partial ;;
  esac
}

# issue_tls_cert <CA key> <CA cert>: generates OpenBao's server key and a
# certificate signed by the CA, into values[openbao-tls-key] and
# values[openbao-tls-cert] of ensure_cluster_secrets.
issue_tls_cert() {
  local key cert
  key=$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256)
  cert=$(openssl req -new -key <(printf '%s\n' "$key") -subj /CN=openbao.openbao.svc \
    -addext basicConstraints=critical,CA:FALSE \
    -addext keyUsage=critical,digitalSignature \
    -addext extendedKeyUsage=serverAuth \
    -addext "subjectAltName=$tlsNames" |
    openssl x509 -req -CA <(printf '%s\n' "$2") -CAkey <(printf '%s\n' "$1") \
      -days "$tlsServerDays" -copy_extensions copyall)
  values["openbao-tls-key"]=$key$'\n'
  values["openbao-tls-cert"]=$cert$'\n'
}

# random_hex <bytes>: prints <bytes> random bytes from /dev/urandom in hex.
random_hex() {
  od -An -v -tx1 -N "$1" /dev/urandom | tr -d ' \n'
}

cmd_keygen() {
  prog="backfabric keygen"

  case "${1-}" in
  -h | --help)
    usage_keygen
    exit 0
    ;;
  esac
  if [[ $# -gt 1 ]]; then
    usage_keygen >&2
    exit 2
  fi
  host=${1-}

  require_flake

  if [[ -z $host ]]; then
    ensure_cluster_secrets
    exit 0
  fi

  check_host_name "$host"
  command -v ssh-keygen >/dev/null || die "no ssh-keygen in PATH"
  require_host "$host"

  # Facts that also work without the public key files.
  facts=$(host_facts "$host" initrdHostKey reportPath)
  initrdHostKey=$(jq -r .initrdHostKey <<<"$facts")
  host_files "$(jq -r '.reportPath // empty' <<<"$facts")"
  [[ $initrdHostKey == /* ]] ||
    die "backfabric.access.initrdSsh.hostKey of $host is not an absolute path: $initrdHostKey"

  state=$(state_dir "$host")
  # The state directory may already hold the pinned Rescue host key of an
  # earlier `backfabric probe`.
  for file in "$state/extra-files" "$state/luks" "$hostPub" "$initrdPub"; do
    [[ ! -e $file ]] || die "$file exists. To start over with new keys, delete $state and both .pub files of $host ($hostPub, $initrdPub); a host that was installed with the old keys then needs a reinstall. For the cluster-wide secrets alone, run backfabric keygen without a host."
  done

  # Before the host's keys: if it fails, the next run is not refused.
  ensure_cluster_secrets
  echo

  # --- Keys and passphrase ----------------------------------------------------

  install -d -m 700 "$state"
  chmod 700 "$state"
  # Generated aside and moved into place at the end, so that a failed run
  # leaves nothing that stops the next one.
  new=$state/keygen.new
  rm -rf "$new"
  install -d -m 755 "$new/extra-files/etc/ssh"
  ssh-keygen -q -t ed25519 -N "" -C "$host" -f "$new/extra-files/etc/ssh/ssh_host_ed25519_key"
  install -d -m 700 "$new/extra-files$(dirname "$initrdHostKey")"
  ssh-keygen -q -t ed25519 -N "" -C "$host-initrd" -f "$new/extra-files$initrdHostKey"

  # 30 characters from 30 letters and digits (about 147 bits), in groups of
  # five: lowercase only, without l, o, y, z, 0 and 1, so that it is
  # unambiguous to read and the same on QWERTY and QWERTZ keyboards.
  alphabet=abcdefghijkmnpqrstuvwx23456789
  random=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc "$alphabet")
  [[ ${#random} -ge 30 ]] || die "not enough random characters from /dev/urandom"
  passphrase=${random:0:5}
  for i in 5 10 15 20 25; do
    passphrase+=-${random:i:5}
  done
  (
    umask 077
    printf '%s' "$passphrase" >"$new/luks"
  )
  unset random passphrase

  # --- Public keys ------------------------------------------------------------

  # A flake in a git repository only sees files in the index; intent-to-add
  # makes the new files visible without staging their content.
  mkdir -p "$(dirname "$report")"
  cp "$new/extra-files/etc/ssh/ssh_host_ed25519_key.pub" "$hostPub"
  cp "$new/extra-files$initrdHostKey.pub" "$initrdPub"
  git add --intent-to-add -- "$hostPub" "$initrdPub"

  mv "$new/extra-files" "$state/extra-files"
  mv "$new/luks" "$state/luks"
  rmdir "$new"

  echo "Generated the keys and the LUKS passphrase of $host in $state."
  echo "Wrote $(realpath --relative-to=. "$hostPub") and $(realpath --relative-to=. "$initrdPub")."
  echo
  if [[ -f .sops.yaml ]]; then
    echo "Next: backfabric sops add-host $host"
    echo "(with --replace if $host is in .sops.yaml with the key of an earlier install)"
  else
    echo "No .sops.yaml; once it exists, add $host with backfabric sops add-host $host."
    echo "Next: boot the server into the Hetzner Rescue system, then: backfabric probe $host"
  fi
}
