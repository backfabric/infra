# Secrets with sops-nix (imported by the registry entry), decrypted with the
# SSH ed25519 host key of the booted system. See docs/secrets.md.
#
# No options of its own: the private repository sets `sops.defaultSopsFile`,
# and other subsystems declare their own `sops.secrets.*`.
{
  sops = {
    # A string, not a Nix path, so that the key is never copied into the Nix
    # store. sops-nix converts it to an age identity with ssh-to-age. The key
    # is generated at install time and copied with nixos-anywhere
    # `--extra-files`, so the first boot can decrypt. sshd uses it as well:
    # the default `services.openssh.hostKeys` contains an ed25519 key at this
    # path, which sshd-keygen only generates if it is missing.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    # The default imports the RSA host key as a GnuPG key; only age is used.
    gnupg.sshKeyPaths = [ ];
  };
}
