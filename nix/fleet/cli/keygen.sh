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
that the cluster-wide secrets exist. In secrets/common.yaml, the sops file
every host can read:
  - k3s-token: the k3s cluster token (32 random bytes, hex);
  - openbao-seal-key: OpenBao's static seal key (32 random bytes, hex);
  - openbao-ca-cert: the CA of the host services' TLS certificates (ECDSA
    P-256, 10 years);
  - openbao-tls-key, openbao-tls-cert: OpenBao's TLS key and certificate
    (ECDSA P-256, 3 years) for openbao.openbao.svc,
    openbao.openbao.svc.cluster.local and 127.0.0.1, signed by that CA;
  - otel-tls-key, otel-tls-cert: the OpenTelemetry Collector's, for
    otel-collector.otel.svc, otel-collector.otel.svc.cluster.local and
    127.0.0.1, signed by that CA.
In secrets/admin.yaml, the sops file of the admins only (its rule in
.sops.yaml is added if missing):
  - openbao-ca-key: the CA's private key. An openbao-ca-key found in
    secrets/common.yaml (where earlier versions put it) is moved here.
Generates only the missing ones and never changes an existing value; with
the CA present and a service's key and certificate both missing, it issues
a new server certificate for it (rotation, docs/openbao.md). Creates a file
if it does not exist, encrypted as .sops.yaml says; adding to an existing
file, issuing a certificate from an existing CA, and moving the CA key need
an admin key. Skipped without .sops.yaml.

Without <host>, only the cluster-wide secrets: for hosts that are already
installed.
EOF
}

commonFile=secrets/common.yaml
adminFile=secrets/admin.yaml

# The random cluster-wide secrets in secrets/common.yaml. Each is generated
# by keygen if missing, and must never change afterwards (the k3s token is
# needed to restore an etcd snapshot, the seal key to unseal OpenBao).
clusterSecrets=(k3s-token openbao-seal-key)

# The TLS material of the host services: one CA, its key in
# secrets/admin.yaml, its certificate in secrets/common.yaml, and for each
# service <service>-tls-key and <service>-tls-cert in secrets/common.yaml.
# The CA keeps OpenBao's name, which it had first.
tlsServices=(openbao otel)
# The names clients use (nix/modules/<service>.nix), and the loopback
# address for clients on the host; the first is the certificate's subject.
declare -A tlsNames=(
  [openbao]="DNS:openbao.openbao.svc,DNS:openbao.openbao.svc.cluster.local,IP:127.0.0.1"
  [otel]="DNS:otel-collector.otel.svc,DNS:otel-collector.otel.svc.cluster.local,IP:127.0.0.1"
)
tlsCaDays=3650
tlsServerDays=1095

# ensure_cluster_secrets: adds the missing cluster-wide secrets to
# secrets/common.yaml and secrets/admin.yaml, creating the files if needed.
ensure_cluster_secrets() {
  local name service caKey caCert missing=() commonNew=() adminNew=()
  # The values stay in this process's memory: they go to openssl and sops
  # through pipes (printf is a builtin), never as arguments or into an
  # unencrypted file.
  local -A values=()
  if [[ ! -f .sops.yaml ]]; then
    echo "No .sops.yaml; once it exists (backfabric sops init), run backfabric keygen to create $commonFile with the cluster-wide secrets."
    return
  fi

  ensure_admin_rule
  if has_secret "$commonFile" openbao-ca-key; then
    move_ca_key
  fi

  for name in "${clusterSecrets[@]}"; do
    if ! has_secret "$commonFile" "$name"; then
      values[$name]=$(random_hex 32)
      commonNew+=("$name")
    fi
  done

  case "$(ca_state)" in
  complete)
    for service in "${tlsServices[@]}"; do
      case "$(server_state "$service")" in
      complete) ;;
      none) missing+=("$service") ;;
      *)
        die "the TLS secrets of $service are incomplete ($service-tls-key, $service-tls-cert in $commonFile). To issue a new server certificate, remove both (sops unset $commonFile '[\"<name>\"]'); see docs/openbao.md"
        ;;
      esac
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      # Rotation or a new service: a server certificate from the existing CA.
      caKey=$(sops decrypt --extract '["openbao-ca-key"]' "$adminFile") ||
        die "cannot read openbao-ca-key from $adminFile; sops needs an admin key (docs/secrets.md)"
      caCert=$(sops decrypt --extract '["openbao-ca-cert"]' "$commonFile") ||
        die "cannot read openbao-ca-cert from $commonFile; sops needs an admin key (docs/secrets.md)"
    fi
    ;;
  none)
    for service in "${tlsServices[@]}"; do
      [[ $(server_state "$service") == none ]] ||
        die "$service-tls-* exist in $commonFile without the CA (openbao-ca-key in $adminFile, openbao-ca-cert in $commonFile). To start over with a new CA, remove every TLS secret (sops unset <file> '[\"<name>\"]'); see docs/openbao.md"
    done
    caKey=$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256)
    caCert=$(openssl req -new -x509 -key <(printf '%s\n' "$caKey") \
      -subj "/CN=OpenBao CA" -days "$tlsCaDays" \
      -addext basicConstraints=critical,CA:TRUE,pathlen:0 \
      -addext keyUsage=critical,keyCertSign,cRLSign)
    values["openbao-ca-key"]=$caKey$'\n'
    values["openbao-ca-cert"]=$caCert$'\n'
    adminNew+=(openbao-ca-key)
    commonNew+=(openbao-ca-cert)
    missing=("${tlsServices[@]}")
    ;;
  *)
    die "the TLS CA is incomplete (openbao-ca-key in $adminFile, openbao-ca-cert in $commonFile). To start over with a new CA, remove it and every <service>-tls-key and -cert (sops unset <file> '[\"<name>\"]'); see docs/openbao.md"
    ;;
  esac
  for service in "${missing[@]}"; do
    issue_tls_cert "$service" "$caKey" "$caCert"
    commonNew+=("$service-tls-key" "$service-tls-cert")
  done
  unset caKey

  if [[ ${#commonNew[@]} -eq 0 && ${#adminNew[@]} -eq 0 ]]; then
    echo "$commonFile and $adminFile have every cluster-wide secret; left unchanged."
    return
  fi
  # The CA key first: if writing the rest fails, the next run reports the
  # incomplete set instead of leaving a certificate whose CA key is lost.
  if [[ ${#adminNew[@]} -gt 0 ]]; then
    put_secrets "$adminFile" "${adminNew[@]}"
  fi
  if [[ ${#commonNew[@]} -gt 0 ]]; then
    put_secrets "$commonFile" "${commonNew[@]}"
  fi
  echo "Commit .sops.yaml and secrets/; hosts read the secrets at their next deployment."
}

# has_secret <file> <name>: whether the sops file exists and has <name>. Only
# the values of a sops file are encrypted, so the names can be read without a
# key.
has_secret() {
  [[ -f $1 ]] && [[ $(name=$2 yq 'has(strenv(name))' "$1") == true ]]
}

# put_secrets <file> <name>...: writes values[<name>] of
# ensure_cluster_secrets into the sops file, creating it if needed.
put_secrets() {
  local file=$1 name
  shift
  if [[ ! -f $file ]]; then
    mkdir -p "$(dirname "$file")"
    # Encrypting needs only the public keys in .sops.yaml. Each value as a
    # JSON string, which YAML reads as well (the PEM values span lines).
    for name; do
      printf '%s: %s\n' "$name" "$(printf '%s' "${values[$name]}" | jq -Rs .)"
    done | sops encrypt --filename-override "$file" >"$file.new" || {
      rm -f "$file.new"
      die "cannot create $file with sops (see above); check the rule for $file in .sops.yaml"
    }
    mv "$file.new" "$file"
    # A flake in a git repository only sees files in the index.
    git add --intent-to-add -- "$file"
    echo "Created $file with $*, encrypted for the keys of its rule in .sops.yaml."
  else
    for name; do
      printf '%s' "${values[$name]}" | jq -Rs . | sops set --value-stdin "$file" "[\"$name\"]" ||
        die "cannot add $name to $file; sops needs an admin key to edit it (docs/secrets.md)"
      echo "Added $name to $file."
    done
  fi
}

# move_ca_key: moves openbao-ca-key from secrets/common.yaml, where earlier
# versions put it, to secrets/admin.yaml.
move_ca_key() {
  if ! has_secret "$adminFile" openbao-ca-key; then
    values["openbao-ca-key"]=$(sops decrypt --extract '["openbao-ca-key"]' "$commonFile")$'\n' ||
      die "cannot read openbao-ca-key from $commonFile to move it to $adminFile; sops needs an admin key (docs/secrets.md)"
    put_secrets "$adminFile" openbao-ca-key
  fi
  sops unset "$commonFile" '["openbao-ca-key"]' ||
    die "cannot remove openbao-ca-key from $commonFile; sops needs an admin key (docs/secrets.md)"
  echo "Moved openbao-ca-key from $commonFile to $adminFile."
  echo "Every host key could decrypt it in $commonFile, and the git history keeps it there: issue a new CA and certificate (docs/openbao.md#tls)."
}

# ca_state: whether the TLS CA exists: complete, none or partial.
ca_state() {
  local count=0
  ! has_secret "$adminFile" openbao-ca-key || count=$((count + 1))
  ! has_secret "$commonFile" openbao-ca-cert || count=$((count + 1))
  case $count in
  2) echo complete ;;
  0) echo none ;;
  *) echo partial ;;
  esac
}

# server_state <service>: whether its TLS key and certificate exist:
# complete, none or partial.
server_state() {
  local count=0
  ! has_secret "$commonFile" "$1-tls-key" || count=$((count + 1))
  ! has_secret "$commonFile" "$1-tls-cert" || count=$((count + 1))
  case $count in
  2) echo complete ;;
  0) echo none ;;
  *) echo partial ;;
  esac
}

# issue_tls_cert <service> <CA key> <CA cert>: generates the service's
# server key and a certificate signed by the CA, for its tlsNames, into
# values[<service>-tls-key] and values[<service>-tls-cert] of
# ensure_cluster_secrets.
issue_tls_cert() {
  local key cert names=${tlsNames[$1]} subject
  subject=${names%%,*}
  key=$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256)
  cert=$(openssl req -new -key <(printf '%s\n' "$key") -subj "/CN=${subject#DNS:}" \
    -addext basicConstraints=critical,CA:FALSE \
    -addext keyUsage=critical,digitalSignature \
    -addext extendedKeyUsage=serverAuth \
    -addext "subjectAltName=$names" |
    openssl x509 -req -CA <(printf '%s\n' "$3") -CAkey <(printf '%s\n' "$2") \
      -days "$tlsServerDays" -copy_extensions copyall)
  values["$1-tls-key"]=$key$'\n'
  values["$1-tls-cert"]=$cert$'\n'
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
