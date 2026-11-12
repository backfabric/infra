# Fleet

Hosts and secrets of a k3s cluster on Hetzner bare metal, built from the
public modules of [backfabric/infra](https://github.com/backfabric/infra).
Keep this repository private: it holds IP addresses, disk ids, and encrypted
secrets.

## Prerequisites

- Nix with flakes enabled, and git.
- Optional: [direnv](https://direnv.net) with
  [nix-direnv](https://github.com/nix-community/nix-direnv), which loads the
  dev shell on entering the directory (`.envrc`). Everything below works in
  `nix develop` as well.
- An SSH key pair; its public key goes into `authorizedKeys` and into the
  Hetzner Robot for the Rescue system. The dev shell uses your default keys
  and ssh-agent, see
  [client keys](https://github.com/backfabric/infra/blob/main/docs/fleet-shell.md#client-keys).
- An admin key for sops: an age key or a PGP key, stored where you like
  (an SSH ed25519 key works through ssh-to-age, see
  [admin keys](https://github.com/backfabric/infra/blob/main/docs/secrets.md#admin-keys)).
  For example an age key:
  `nix shell nixpkgs#age -c age-keygen -o ~/.config/sops/age/fleet.txt`.
  Tell sops where it is in the `shellHook` in `flake.nix`.
- This line as the FIRST line of `~/.ssh/config`, once per machine:

  ```
  Include ${PROJECT_SSH_CONFIG}
  ```

  The dev shell exports `PROJECT_SSH_CONFIG`, the generated SSH config of
  the fleet; outside the shell the variable is unset and ssh skips the
  line. It must come first because ssh keeps the first value of each
  option, so the fleet's user, ports, and host key checking win over your
  own `Host *` settings. Without it, `node1` is an ordinary host name,
  checked against your personal known_hosts; see
  [the fleet dev shell](https://github.com/backfabric/infra/blob/main/docs/fleet-shell.md#one-time-setup-of-sshconfig).

## Create the repository

```sh
mkdir fleet && cd fleet
nix flake init -t github:backfabric/infra
git init
git add -A
git commit -m "chore: initial fleet repository"
```

A flake in a git repository only sees files known to git: `git add` every new
file before running a command.

The fleet dev shell provides `nixos-rebuild`, `nixos-anywhere`, `sops`, the
`backfabric` command, and `PROJECT_SSH_CONFIG`, through which `ssh`, `scp`,
`nix copy`, and the rest know every host in `nixosConfigurations`. Enter it
with `direnv allow` (once; afterwards it loads whenever you `cd` into the
repository and reloads when `flake.nix`, `flake.lock`, or `hosts/` change)
or with `nix develop`. Create `.sops.yaml` with your admin key(s), once:

```sh
direnv allow                         # or: nix develop
backfabric sops init --age age1...   # --age and --pgp, repeatable
git add .sops.yaml && git commit -m "chore: add sops configuration"
```

See [secrets](https://github.com/backfabric/infra/blob/main/docs/secrets.md)
for the layout of `.sops.yaml` and the secret files.

## Add a host

Order the server and note its data from the Hetzner Robot. Create
`hosts/<host>/default.nix` (here `node1`); the disk ids and the MAC can wait
for the hardware summary of `backfabric probe` (step 3 below):

```nix
{
  networking.hostName = "node1";
  # NixOS release of the first install; keep it when upgrading.
  system.stateVersion = "26.05";

  # System disks, whole disks by id: from the summary of `backfabric probe`.
  backfabric.disks.devices = [
    "/dev/disk/by-id/nvme-..."
    "/dev/disk/by-id/nvme-..."
  ];

  backfabric.network = {
    # MAC of the uplink (Robot, or `backfabric probe`, which checks it).
    macAddress = "aa:bb:cc:dd:ee:ff";
    # Robot, server, IPs: the main IPv4 address and its gateway.
    ipv4.address = "203.0.113.10";
    ipv4.gateway = "203.0.113.1";
  };

  backfabric.access = {
    # Your SSH public key(s): root login and unlocking the disks.
    authorizedKeys = [ "ssh-ed25519 AAAA... you@laptop" ];
    # Your choice: SSH port of the booted system (the only open port).
    ssh.port = 2222;
    # Your choice: SSH port of the initrd, to unlock the disks.
    initrdSsh.port = 2223;
    # Written by `backfabric keygen`.
    hostKey.publicKey = builtins.readFile ./ssh_host_ed25519_key.pub;
    # Written by `backfabric keygen`.
    initrdSsh.publicKey = builtins.readFile ./initrd_ssh_host_ed25519_key.pub;
  };

  # Written by `backfabric probe` (nixos-facter).
  hardware.facter.reportPath = ./facter.json;

  # Once the host has secrets:
  # sops.defaultSopsFile = ../../secrets/node1.yaml;
}
```

Register it in `flake.nix` and add both to git:

```nix
nixosConfigurations = {
  node1 = mkHost ./hosts/node1;
};
```

```sh
git add flake.nix hosts/node1
```

## Install

Each step does one thing, prints the next one, and can be run again after a
failure; see
[installing a host](https://github.com/backfabric/infra/blob/main/docs/fleet-shell.md#installing-a-host)
for details and what to re-run after which failure.

1. Generate the host's SSH host keys and LUKS passphrase, locally, into
   `~/.local/state/backfabric/node1/`; the `.pub` files go into
   `hosts/node1/`. Until they exist, the dev shell does not evaluate (it
   reads every host's public keys; direnv keeps the previous environment and
   prints the error), hence `nix run` from the pinned `backfabric` input:

   ```sh
   nix run --inputs-from . backfabric -- keygen node1
   ```

   The first time, it also creates `secrets/common.yaml` with the
   cluster-wide secrets: the k3s cluster token, OpenBao's seal key, CA
   and TLS certificate, and the OpenTelemetry Collector's TLS certificate;
   the CA's key goes into `secrets/admin.yaml`, which
   only the admins can read (encrypted as `.sops.yaml` says; it never
   changes an existing value). From here on, work in the dev shell.

2. Add the host to `.sops.yaml` (this re-encrypts `secrets/common.yaml` for
   it):

   ```sh
   backfabric sops add-host node1
   ```

3. Activate the Rescue system for the server in the Robot (with your SSH
   key), reset the server, and probe it: compare the host key fingerprints
   with the Robot's, then the server boots into the NixOS installer (nothing
   is written to the disks) and its hardware report is written to
   `hosts/node1/facter.json`. The command prints a hardware summary,
   evaluates the configuration, and checks the MAC. Fill in what is missing
   (disk ids, MAC) and run it again until it succeeds:

   ```sh
   backfabric probe node1
   ```

4. Review the report and commit:

   ```sh
   git add -A && git commit -m "feat: add node1"
   ```

5. Install (ERASES ALL DISKS); the host reboots into the initrd:

   ```sh
   backfabric install node1
   ```

6. Once it is up, send the LUKS passphrase:

   ```sh
   backfabric unlock node1
   ```

7. Once it has booted, finish: the command checks `ssh node1`, asks you to
   store the LUKS passphrase in your password manager, and deletes the
   local state directory:

   ```sh
   backfabric finalize node1
   ```

## The cluster

Every host runs a k3s server that initializes its own cluster on embedded
etcd; joining further nodes is not implemented yet, so a cluster is one
host for now. The cluster token, `k3s-token` in `secrets/common.yaml`
(read through `backfabric.secrets.commonFile`, set in `mkHost` in
`flake.nix`), must never change: an etcd snapshot can only be restored
with it. Keep it with the rest of this repository.

The cluster is hardened as the
[K3s CIS hardening guide](https://docs.k3s.io/security/hardening-guide)
says; nothing in it is reachable from outside: the Kubernetes API is not
exposed, and Services of type NodePort or LoadBalancer, or with
`externalIPs`, are rejected. Pod Security Admission enforces `restricted` in
every namespace except kube-system: pods must run as non-root, with
`allowPrivilegeEscalation: false`, all capabilities dropped, and the
`RuntimeDefault` seccomp profile. See
[ADR 0017](https://github.com/backfabric/infra/blob/main/docs/adr/0017-cluster-hardening-defaults.md).

Use `kubectl` on the host:

```sh
ssh node1
kubectl get nodes
kubectl get pods -A
```

Every API request is recorded (who, what, which object, the result; no
request or response bodies) in `/var/lib/rancher/k3s/server/logs/audit.log`
on the host, one JSON object per line, rotated at 100 MB (10 files, at most
30 days):

```sh
ssh node1 tail -f /var/lib/rancher/k3s/server/logs/audit.log
```

The k3s version is pinned to a minor release
(`backfabric.k3s.package`, default `pkgs.k3s_1_36`), so `nix flake update`
only brings patch releases. A new minor version arrives as a new default of
this flake, or by setting it in the host's configuration, e.g.
`backfabric.k3s.package = pkgs.k3s_1_37;` (with `pkgs` among the module
arguments). Minor versions are upgraded one at a time and cannot be
downgraded: the new version migrates etcd, so take a snapshot first and
deploy with `switch`, not `test` (a reboot after `test` would start the old
version on the migrated datastore):

```sh
ssh node1 k3s etcd-snapshot save --name before-upgrade
backfabric deploy node1
ssh node1 kubectl version
```

If the hosts were installed before a cluster-wide secret existed (e.g.
OpenBao's, added after the k3s token), create the missing ones once in the
dev shell (needs your admin key if `secrets/common.yaml` exists; it also
adds the rule for `secrets/admin.yaml` to `.sops.yaml` and moves an
`openbao-ca-key` found in `secrets/common.yaml` there, after which you
replace the CA, see
[OpenBao](https://github.com/backfabric/infra/blob/main/docs/openbao.md#tls)),
then commit and deploy:

```sh
backfabric keygen
git add .sops.yaml secrets/ && git commit -m "chore: add the missing cluster-wide secrets"
backfabric deploy node1
```

## OpenBao

Every host runs OpenBao next to k3s, for the secrets of the workloads. It
unseals and initialises itself; the root token is in
`/var/lib/openbao-init/root-token` on the host (root only). Use it there:

```sh
ssh node1
export BAO_TOKEN=$(cat /var/lib/openbao-init/root-token)
bao status
```

Pods reach it as `https://openbao.openbao.svc:8200`, trusting the CA
`openbao-ca-cert` of `secrets/common.yaml`. What it holds is configured in
the host's configuration; policies and roles not declared there are
deleted. Permanent secrets come from the host's sops file
(`sops.defaultSopsFile`):

```nix
backfabric.openbao = {
  policies.my-app = ''
    path "secret/data/my-app/*" {
      capabilities = ["read"]
    }
  '';
  # Each service account also needs the ClusterRole system:auth-delegator.
  kubernetesRoles.my-app = {
    serviceAccounts = [ "my-app" ];
    namespaces = [ "my-app" ];
    policies = [ "my-app" ];
  };
  # secret/my-app/db, field password = the sops secret my-app-db-password.
  kv.secrets."my-app/db".password = "my-app-db-password";
};
```

Snapshots, restore, the audit log, and renewing the TLS certificate:
[OpenBao](https://github.com/backfabric/infra/blob/main/docs/openbao.md).

## Audit telemetry

Every host runs an OpenTelemetry Collector next to k3s that archives the
telemetry of the workloads in `/var/log/otel-collector` (root only). Pods
send OTLP to `otel-collector.otel.svc:4317` (gRPC) or `:4318` (HTTP) over
TLS, trusting `openbao-ca-cert`, with a projected service account token
for the audience `otel-collector`; the namespace and service account in
the archive come from that token. Its certificate is generated by
`backfabric keygen` (hosts installed before: run it once, commit, deploy).
Sending, reading the archive, and renewing the certificate:
[audit telemetry](https://github.com/backfabric/infra/blob/main/docs/otel.md).

## Unlock after a reboot

After every reboot the host waits for the LUKS passphrase in the initrd.
In the dev shell, type it at the prompt or pipe it in:

```sh
backfabric unlock node1
op read "op://Fleet/node1/LUKS passphrase" | backfabric unlock node1
```

See [unlocking the disks](https://github.com/backfabric/infra/blob/main/docs/initrd-unlock.md).

## Update a host

Commit the change, then in the dev shell (the host builds its own
system; the operator machine only evaluates):

```sh
backfabric deploy node1          # switch; also: boot, test
```

Nothing rolls back automatically yet: if a change breaks networking or SSH,
recover from the Hetzner Rescue system. See
[updating a host](https://github.com/backfabric/infra/blob/main/docs/fleet-shell.md#updating-a-host)
for what the command runs.

Update the inputs with `nix flake update`.
