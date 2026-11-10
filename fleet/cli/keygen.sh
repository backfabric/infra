# backfabric keygen: generates the keys and the LUKS passphrase of a host
# before its installation. See docs/fleet-shell.md.

usage_keygen() {
  cat <<'EOF'
Usage: backfabric keygen <host>

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
EOF
}

cmd_keygen() {
  prog="backfabric keygen"

  case "${1-}" in
  -h | --help)
    usage_keygen
    exit 0
    ;;
  esac
  if [[ $# -ne 1 ]]; then
    usage_keygen >&2
    exit 2
  fi
  host=$1

  check_host_name "$host"
  require_flake
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
    [[ ! -e $file ]] || die "$file exists. To start over with new keys, delete $state and both .pub files of $host ($hostPub, $initrdPub); a host that was installed with the old keys then needs a reinstall."
  done

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
