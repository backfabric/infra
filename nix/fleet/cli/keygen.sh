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
  - k3s-token: the k3s cluster token (32 random bytes, hex).
Generates only the missing ones and never changes an existing value. Creates
the file if it does not exist, encrypted as .sops.yaml says; adding to an
existing file needs an admin key. Skipped without .sops.yaml.

Without <host>, only the cluster-wide secrets: for hosts that are already
installed.
EOF
}

# The cluster-wide secrets in secrets/common.yaml. Each is random, generated
# by keygen if missing, and must never change afterwards (the k3s token is
# needed to restore an etcd snapshot).
clusterSecrets=(k3s-token)

# ensure_cluster_secrets: adds the missing cluster-wide secrets to
# secrets/common.yaml, creating the file if needed.
ensure_cluster_secrets() {
  local file=secrets/common.yaml name missing=() value
  if [[ ! -f .sops.yaml ]]; then
    echo "No .sops.yaml; once it exists (backfabric sops init), run backfabric keygen to create $file with the cluster-wide secrets."
    return
  fi

  # Only the values of a sops file are encrypted, so the names can be read
  # without a key.
  for name in "${clusterSecrets[@]}"; do
    if [[ ! -f $file ]] || [[ $(name=$name yq 'has(strenv(name))' "$file") != true ]]; then
      missing+=("$name")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "$file has every cluster-wide secret (${clusterSecrets[*]}); left unchanged."
    return
  fi

  # Values go to sops on stdin (printf is a builtin), never as arguments or
  # into an unencrypted file.
  if [[ ! -f $file ]]; then
    mkdir -p "$(dirname "$file")"
    # Encrypting needs only the public keys in .sops.yaml.
    for name in "${missing[@]}"; do
      printf '%s: %s\n' "$name" "$(random_hex 32)"
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
      value=$(random_hex 32)
      printf '"%s"' "$value" | sops set --value-stdin "$file" "[\"$name\"]" ||
        die "cannot add $name to $file; sops needs an admin key to edit it (docs/secrets.md)"
      echo "Added $name to $file."
    done
    unset value
  fi
  echo "Commit $file; hosts read it at their next deployment."
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
