# Public modules, private fleet repository

This repository is a public flake of reusable NixOS modules and operator tooling; everything about concrete machines (IP and MAC addresses, disk ids, facter reports, public host keys, encrypted secrets) lives in the user's private repository, created from `templates.default`. Public code is consumer-agnostic: the kind and location of sops admin keys, SSH client keys and agents, the password manager, and `~/.ssh` stay the operator's business, so the modules can serve any fleet without leaking one.
