---
status: amended by ADR 0022 and ADR 0026
---

# CI evaluates, the real server validates

CI runs `nix flake check --no-build --all-systems` and the formatter check only: no builds and no NixOS VM tests. The development machine is aarch64-darwin without a Linux builder, VM tests of LUKS, initrd networking, and Hetzner-style routing would be costly to maintain, and installation on a real Hetzner server covers more than they could. Evaluation checks still pin the contracts that can be checked statically (examples, assertions against facter reports, the template).
