---
status: amended by ADR 0030
---

# Agent Substrate as the agent runtime

Agents run as [Agent Substrate](https://github.com/agent-substrate/substrate) actors (release v1.0.0): each agent is a long-lived actor in a gVisor sandbox on a warm worker pod, suspended to a snapshot between tasks and resumed on the next request, with its memory, root file system and durable volumes. Substrate gives per-actor identity, ingress through one router, and per-actor egress policy (TLS passthrough or interception by host name), which is what agents need and what we would otherwise build. The `substrate` subsystem installs it on the cluster (`nix/modules/substrate.nix`, runbook docs/substrate.md).

Its dependencies run in the cluster, on the same node, not on the host: Substrate's bundled PostgreSQL (mutual TLS with pod certificates, certificate authentication) and RustFS as the S3 store for snapshots, each on a static `local` PersistentVolume in `/var/lib/substrate` (the encrypted btrfs file system, ADR 0003), bound to its claim by name, with a storage class no provisioner serves and no StorageClass object: nothing else in the cluster can get a volume. In the cluster, a NetworkPolicy admits each of them only from the Substrate pods that use it (ate-system denies all other ingress). A service on the host can only be opened to all of `cni0`, i.e. to every pod, as OpenBao and the Collector are (ADR 0009, 0021), and these two hold the agents' state and their logins.

Substrate is installed by its own installer: a oneshot runs `ate-setup deploy ate-system` with a SubstrateInstall document generated in Nix, at every deployment that changes it or the package, from the release's prebuilt images. `ate-setup` cannot be given an overlay of its own, so the package patches the manifest tree it reads (S3 instead of GCS with credentials from a Secret, GKE-only resources and host paths removed, telemetry export off, a smaller PostgreSQL claim, a seccomp profile for the pod certificate controller) and checks at build time what each patch replaces, the images every pod of ate-system can run, and that every object it applies is of a Kubernetes API group or of a CRD in the tree. A new release changes these in one place and fails the build, not the install.

Substrate's pod certificates need the Kubernetes features ClusterTrustBundle, ClusterTrustBundleProjection and PodCertificateRequest, beta and off by default in 1.35 and 1.36: k3s gets the three feature gates on the API server, controller manager and kubelet, and `runtime-config` for exactly the two `certificates.k8s.io/v1beta1` resources, only while the subsystem is enabled.

atelet runs as root with host paths (including `/dev`) and four capabilities, the bundled PostgreSQL's main container as root, and every worker pod as root with a host path, SYS_ADMIN, NET_ADMIN and seven more capabilities, seccomp and AppArmor Unconfined. None of this passes Pod Security `restricted` or `baseline`, so the subsystem exempts `ate-system` and each namespace that holds WorkerPools (`backfabric.substrate.workerPoolNamespaces`) through the mechanism of ADR 0024, with these images, pinned by digest: in ate-system the release's components, PostgreSQL, RustFS and aws-cli (checked at build time against the patched manifests); in a WorkerPool namespace only the release's gVisor worker image. The actors' own images run inside the worker's sandbox, not as containers of the pod.

Only the gVisor sandbox class is installed (no microVMs: no `/dev/kvm`, no asset staging). Egress credential injection is off; only `kubectl ate proxy`'s identity may reach actors through the router; the bootstrap owners are pinned. Telemetry export is off until Substrate can authenticate to the host's Collector.

## Considered Options

- [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) with Kueue: Kubernetes-native sandboxes (one pod per sandbox) with gVisor as a RuntimeClass, queued by Kueue. No suspend/resume of memory state, no per-sandbox identity, ingress or egress policy: we would build those.
- AX and similar hosted agent runtimes: the agents and their logins would run outside our cluster and audit.
- PostgreSQL and S3 on the host, as NixOS services: reachable from every pod through `cni0` (the host firewall cannot tell pods apart), a second state location outside the cluster's NetworkPolicy, and Substrate's PostgreSQL authentication by pod certificate would need the host to trust the cluster's signers.
- [Garage](https://garagehq.deuxfleurs.fr/) instead of RustFS: a good small S3 server, but upstream installs and tests Substrate with RustFS (its kind install); Garage would be one more untested combination.
- A dynamic local-path provisioner (k3s's `local-storage`): every claim in the cluster could then get a host directory; disabled in ADR 0017.
- `ate-setup --kind`: needs Docker and the kind overlay (in-cluster collector, Prometheus, local registry).

## Consequences

- Residual risk of the exemptions beyond ADR 0024's: the ate-system list includes images with a shell (PostgreSQL, aws-cli, RustFS), and ate-controller's ClusterRole may create Deployments in any namespace, so whoever controls ate-controller, or can create pods or controllers in ate-system, can run a listed image there as root with host paths. Outside the exempt namespaces `restricted` still applies to whatever it creates.
- Every namespace with WorkerPools must be listed in `workerPoolNamespaces`; a WorkerPool elsewhere gets its worker pods rejected by Pod Security.
- The snapshots in RustFS hold the agents' memory, including their Codex logins: `/var/lib/substrate` is as sensitive as the subscriptions.
- k3s restarts when the subsystem is enabled or disabled (its flags change). With the subsystem off, its k3s manifests are removed (`backfabric.k3s.removedManifests`): every host gets three more `--disable` entries (four with ADR 0024's policy), and a host that had Substrate loses the `ate-system` namespace. Substrate's cluster-wide objects, WorkerPools and host data stay; docs/substrate.md has the manual cleanup.
- The pod certificate features are beta: each Kubernetes minor upgrade must check them before k3s is upgraded.
- Actor images are pulled anonymously (no registry credentials for atelet), so they must be public (ADR 0022).
- Upgrading Substrate means new image digests in `nix/packages/substrate.nix`; the build checks catch new images and API groups, not changed security contexts.
