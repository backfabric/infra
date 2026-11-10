# Fleet SSH config through `Include ${PROJECT_SSH_CONFIG}`

The fleet dev shell only exports `PROJECT_SSH_CONFIG`, the path of a generated SSH config (aliases `<host>` and `<host>-initrd`, ports, `User root`, pinned host keys with strict checking); the operator's `~/.ssh/config` includes it with `Include ${PROJECT_SSH_CONFIG}` as its first line. OpenSSH expands environment variables in `Include` paths and skips the line when the variable is unset, so every SSH client (ssh, scp, sftp, rsync, git, nix, nixos-rebuild, nixos-anywhere, `/usr/bin/ssh`) knows the fleet inside the shell and nothing changes outside it.

## Considered Options

- An `ssh` wrapper first in `PATH` adding `-F`: replaced, because scp, sftp, and anything calling `/usr/bin/ssh` bypass it.
- Writing to `~/.ssh`: the operator's files are left alone (ADR 0001).
