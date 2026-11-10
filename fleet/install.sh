# Installs a host of the private repository from the Hetzner Rescue system
# with nixos-anywhere. Run by writeShellApplication (bash, errexit, nounset,
# pipefail). See docs/fleet-shell.md.

usage() {
  cat <<'EOF'
Usage: backfabric-install <host>

Installs nixosConfigurations.<host> of the flake in the current directory, the
root of the private repository (a git repository), on a server booted into the
Hetzner Rescue system. ERASES ALL DISKS of the server.

Steps:
  1. Connect to the Rescue system (root, port 22), pin its host key in a
     temporary known_hosts and show its fingerprint for comparison.
  2. Generate the SSH host key and the initrd host key.
  3. Read the LUKS passphrase.
  4. Write the public keys next to the host's nixos-facter report
     (hardware.facter.reportPath): ssh_host_ed25519_key.pub and
     initrd_ssh_host_ed25519_key.pub. If .sops.yaml exists, add the host to
     it with `backfabric-sops-add-host --replace`, which also runs
     `sops updatekeys` on the host's files.
  5. Run nixos-anywhere (build on the server), generating the nixos-facter
     report first if it is missing.

The private keys only exist in a temporary directory that is always deleted.
Nothing is written to ~/.ssh.
EOF
}

die() {
  echo "backfabric-install: $*" >&2
  exit 1
}

case "${1-}" in
-h | --help)
  usage
  exit 0
  ;;
esac
if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi
host=$1

# --- Facts of the host ------------------------------------------------------

[[ -f flake.nix ]] || die "no flake.nix in $PWD; run from the root of the private repository"
repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "$PWD is not in a git repository"
# The SSH client is the operator machine's own (in the fleet shell, `ssh` is
# its wrapper, which uses that client too).
command -v ssh >/dev/null || die "no ssh in PATH"
command -v ssh-keygen >/dev/null || die "no ssh-keygen in PATH"

hosts=$(nix eval --json .#nixosConfigurations --apply builtins.attrNames) ||
  die "cannot evaluate nixosConfigurations of $PWD"
jq -e --arg host "$host" 'index($host) != null' <<<"$hosts" >/dev/null ||
  die "no nixosConfigurations.$host; hosts: $(jq -r 'join(", ")' <<<"$hosts")"

# fleet/facts.nix ($factsNix, set by fleet/install.nix) works without a
# facter report; the facts read here also work without the public key files.
# Passed as text: pure evaluation may not import it from its path.
facts=$(nix eval --json ".#nixosConfigurations.\"$host\"" \
  --apply "system: { inherit (($(<"$factsNix")) system) address initrdHostKey reportPath; }")
address=$(jq -r .address <<<"$facts")
initrdHostKey=$(jq -r .initrdHostKey <<<"$facts")
reportPath=$(jq -r '.reportPath // empty' <<<"$facts")

[[ $initrdHostKey == /* ]] ||
  die "backfabric.access.initrdSsh.hostKey of $host is not an absolute path: $initrdHostKey"

# The report is a path in the flake source, which is the git repository
# copied to the Nix store; map it back to the working tree. Its directory is
# the host's directory, which also receives the public keys.
[[ -n $reportPath ]] ||
  die "hardware.facter.reportPath of $host is not set; set it to e.g. ./facter.json next to the host's configuration"
[[ $reportPath =~ ^/nix/store/[^/]+/(.+)$ ]] ||
  die "hardware.facter.reportPath of $host is not a file in the repository: $reportPath"
report=$repo/${BASH_REMATCH[1]}
hostDir=$(dirname "$report")
hostPub=$hostDir/ssh_host_ed25519_key.pub
initrdPub=$hostDir/initrd_ssh_host_ed25519_key.pub

for pub in "$hostPub" "$initrdPub"; do
  [[ ! -e $pub ]] ||
    die "$pub exists; to reinstall $host with new host keys, delete both .pub files"
done

# --- Temporary directory ----------------------------------------------------

tmp=$(mktemp -d)
installed=n
generated=n
# The private keys only exist in $tmp: after a failure, the public keys are
# useless and must not stay behind.
cleanup() {
  rm -rf "$tmp"
  [[ $installed == n && $generated == y ]] || return 0
  echo >&2
  echo "backfabric-install: not installed; the generated private keys are deleted." >&2
  if [[ -e $hostPub ]]; then
    echo "Unless $host was installed nevertheless, delete $hostPub and $initrdPub." >&2
    echo "The next install replaces the key of $host in .sops.yaml, if any." >&2
  fi
}
trap cleanup EXIT

# --- 1. Hetzner Rescue host key ---------------------------------------------

rescueKnownHosts=$tmp/rescue_known_hosts
echo "Connecting to the Hetzner Rescue system at root@$address (port 22) ..."
ssh -p 22 \
  -o UserKnownHostsFile="$rescueKnownHosts" \
  -o GlobalKnownHostsFile=none \
  -o StrictHostKeyChecking=accept-new \
  "root@$address" true
echo "Rescue host key (compare with the fingerprints shown in the Hetzner Robot):"
ssh-keygen -l -f "$rescueKnownHosts"
ssh-keygen -l -E md5 -f "$rescueKnownHosts"
read -r -p "Do they match? [y/N] " answer
[[ $answer == [yY] ]] || die "aborted"

# nixos-anywhere passes `-o StrictHostKeyChecking=no -o
# UserKnownHostsFile=/dev/null` to ssh, and ssh uses the first value of an
# option, so its `--ssh-option` cannot enable checking. This ssh, first in
# PATH for nixos-anywhere and the nix and ssh-copy-id it runs, puts the pinned
# Rescue key first. The kexec installer keeps the Rescue host keys.
mkdir "$tmp/bin"
printf '#!%s\nexec %q -o UserKnownHostsFile=%q -o StrictHostKeyChecking=yes "$@"\n' \
  "$BASH" "$(command -v ssh)" "$rescueKnownHosts" >"$tmp/bin/ssh"
chmod +x "$tmp/bin/ssh"

# --- 2. Host keys -------------------------------------------------------------

extraFiles=$tmp/extra-files
install -d -m 755 "$extraFiles/etc/ssh"
ssh-keygen -q -t ed25519 -N "" -C "$host" -f "$extraFiles/etc/ssh/ssh_host_ed25519_key"
install -d -m 700 "$extraFiles$(dirname "$initrdHostKey")"
ssh-keygen -q -t ed25519 -N "" -C "$host-initrd" -f "$extraFiles$initrdHostKey"
generated=y

# --- 3. LUKS passphrase -------------------------------------------------------

echo
read -r -s -p "LUKS passphrase for the disks of $host: " passphrase
echo
read -r -s -p "Repeat the passphrase: " repeated
echo
[[ -n $passphrase ]] || die "empty passphrase"
[[ $passphrase == "$repeated" ]] || die "the passphrases differ"
(
  umask 077
  printf '%s' "$passphrase" >"$tmp/disk-encryption.key"
)
unset passphrase repeated

# --- 4. Public keys and sops --------------------------------------------------

# A flake in a git repository only sees files in the index; intent-to-add
# makes the new files visible without staging their content.
mkdir -p "$hostDir"
cp "$extraFiles/etc/ssh/ssh_host_ed25519_key.pub" "$hostPub"
cp "$extraFiles$initrdHostKey.pub" "$initrdPub"
git add --intent-to-add -- "$hostPub" "$initrdPub"

# The new host key replaces any old one: existing .pub files stopped the
# command above, so a reinstall is deliberate.
if [[ -f .sops.yaml ]]; then
  echo
  backfabric-sops-add-host --replace "$host"
else
  echo "No .sops.yaml; add $host with backfabric-sops-add-host once it exists (docs/secrets.md)."
fi

# --- 5. Install ---------------------------------------------------------------

# A flake in a git repository only sees files in the index; intent-to-add
# makes the new files visible without staging their content.
mkdir -p "$hostDir"
cp "$extraFiles/etc/ssh/ssh_host_ed25519_key.pub" "$hostPub"
cp "$extraFiles$initrdHostKey.pub" "$initrdPub"
git add --intent-to-add -- "$hostPub" "$initrdPub"

anywhereArgs=(
  --flake ".#$host"
  --build-on remote
  --extra-files "$extraFiles"
  --disk-encryption-keys /tmp/disk-encryption.key "$tmp/disk-encryption.key"
)
if [[ -e $report ]]; then
  git add --intent-to-add -- "$report"
else
  # Written after the kexec, before the flake is evaluated; nixos-anywhere
  # adds it with intent-to-add as well.
  anywhereArgs+=(--generate-hardware-config nixos-facter "$report")
fi

PATH="$tmp/bin:$PATH" nixos-anywhere "${anywhereArgs[@]}" "root@$address"
installed=y

cat <<EOF

Installed $host. Next steps:
  1. Commit the new files and the sops changes:
       $(realpath --relative-to=. "$hostPub")
       $(realpath --relative-to=. "$initrdPub")
       $(realpath --relative-to=. "$report")
       .sops.yaml and the files updated by sops
  2. Re-enter the dev shell (nix develop) so that it knows the new host keys.
  3. After every boot, unlock the disks: ssh $host-initrd, then systemctl default
     (docs/initrd-unlock.md).
  4. Log in: ssh $host
EOF
