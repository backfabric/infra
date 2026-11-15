# kagent behind agentgateway as the agent platform

Supersedes ADR 0022, ADR 0023, ADR 0024 and ADR 0028.

Agents run on [kagent](https://kagent.dev/) v1.0.x (CNCF Sandbox, Apache-2.0) with the Agent Substrate fork that kagent installs itself (kagent v1.0.1 pairs with `kagent-dev/substrate` v1.0.0). [agentgateway](https://agentgateway.dev/) (Linux Foundation/AAIF, Apache-2.0) stands in front of kagent's A2A endpoints and is the only way in for callers: it verifies the callers' JWTs, authorizes each call with CEL rules (caller → agent → principal, deny by default), and writes the audit as an OTLP access log to the Collector (ADR 0021). A NetworkPolicy admits only agentgateway and kagent's own components (its runtimes and UI, which use the controller's :8083 and TaskStore gRPC) to kagent's controller; the exact list is settled with agentgateway ([#112](https://github.com/backfabric/infra/issues/112)). The platform is delivered by Nix: kagent with its Substrate fork by kagent's own installer, run by Nix (ADR 0030); agentgateway as its upstream chart through `services.k3s.autoDeployCharts`, like the rest of the platform, in a later PR. Flux delivers only the agents (`Agent`, `ModelConfig`, `Harness` objects) from the private repository, as a restricted service account (ADR 0027).

This is the platform's production path. Like any decision here it is replaced only if it fails in operation; little of it is hard to reverse, because it lives in the cluster as upstream releases and its state in its own database. kagent is installed by its own installer, run by Nix (ADR 0030).

Our own agent runtime is removed: our `substrate` subsystem (upstream Agent Substrate v1.0.0, ADR 0023), its Pod Security exemption mechanism (ADR 0024), the agent image and its A2A supervisor (`agent/`, `nix/images/`, ADR 0022), and the planned dispatcher (ADR 0028). kagent's installer puts its own Substrate fork into `ate-system`, with the same CRD group, CA Secrets and DaemonSet as the upstream install, and there is no supported side-by-side mode; its Codex harness, with the model API key injected at egress, replaces our image.

Reasons:

- Minimal own code. kagent covers the job of ADR 0028's dispatcher almost entirely: agents as Kubernetes objects (`Agent`, `Harness`, `AgentTemplate`, `ModelConfig`, `EgressPolicy` in `api.kagent.dev/v1alpha3`), an A2A 1.0 endpoint per agent, a Postgres task store (GetTask without waking the actor), one actor per session (`contextId`) created, woken and suspended by kagent, push notifications with retries, `ScheduledRun` for cron, Codex and Claude harnesses whose API keys never enter the sandbox (egress credential injection), and a UI. agentgateway covers what kagent's open-source edition lacks: verified authentication, authorization and audit, as configuration.
- What remains ours is the Nix that deploys the charts (versions, values), agentgateway's routes, JWT providers and CEL rules, the NetworkPolicy, and, in the private repository, the agents' objects that Flux applies.

## Considered Options

- Our dispatcher (ADR 0028): an A2A front door with authentication, authorization, durable intake, a Hatchet queue, actor lifecycle and push in our own Go service (about 1,200 lines for intake alone, before the queue and turns). The most code of all options, for jobs kagent already does.
- agentgateway in front of our upstream Substrate and our a2a-sdk supervisor (one actor per agent, the record in the actor's snapshot, busy-reject, best-effort push): less code than the dispatcher, but agentgateway's packaging, its config generation, an idle-suspend loop and the supervisor's task store, idempotency and recovery would still be ours.
- Hatchet with an A2A adapter (ADR 0028 with authentication moved to agentgateway): no A2A↔workflow adapter exists beyond samples, so the adapter is the dispatcher minus authentication.

## Consequences

Costs and risks, from the research behind this decision:

- Freshness: kagent 1.0.0 shipped on 2026-11-09 and 1.0.1 on 2026-11-12, with several releases a week around GA. The 1.0 schema "requires a clean database", and controller and runtime images must match exactly; upgrades may mean starting from a clean database.
- The Substrate fork: `kagent-dev/substrate` is 82 commits ahead of upstream and set as a `replace` in kagent's `go.mod`; whether kagent runs on upstream Substrate is unverified. We follow kagent's fork, not upstream.
- Kubernetes 1.37: kagent's installation guide requires it, because `PodCertificateRequest` and `ClusterTrustBundle` are GA only from 1.37; at 1.36 (`k3s_1_36`, our default) they are beta and off. A host with kagent sets `backfabric.k3s.package` to 1.37 or later from its own nixpkgs; the `kagent` subsystem refuses older versions (ADR 0030).
- kagent's open-source authentication and authorization are permissive: the default mode `insecure` trusts an `X-User-Id` header, `trusted-proxy` parses JWTs without verifying the signature, and the `Authorizer` defaults to `NoopAuthorizer`, which permits everything, checked at session creation only. So agentgateway with verified JWTs and CEL rules must front it, and a NetworkPolicy must admit only agentgateway and kagent's own components to the controller ([#112](https://github.com/backfabric/infra/issues/112)).
- Open core: verified OIDC inside the controller and runtime-changeable RBAC (`EnterpriseKagentRBACPolicy`) are in Solo's closed Enterprise edition.
- Substrate's Postgres connection cannot verify a private CA: "Agent Substrate cannot mount a CA file in this release, so the Agent Substrate connection strings cannot verify a server certificate that a private CA signed." The platform PostgreSQL (ADR 0025) has CloudNativePG's own CA; kagent's controller can mount it, Substrate's components cannot.
- Busy sessions reject: one task per session; a second message gets `KAGENT_SEND_NOT_ACCEPTED` with `retryAfterMs`, nothing is queued, there is no global cap and no automatic turn retry, and a crashed runtime needs a manual `RevertSession`.
- Follow-ups are not idempotent: only the first message of a session is deduplicated (by creator, agent and `messageId`).
- Delegation is deferred: cross-session agent-to-agent calls through the gateway are not supported yet, and the default actor policy forbids an agent from opening a conversation with another.
- kagent's Substrate fork needs Pod Security exemptions for `ate-system` (atelet runs as root with host paths) and for its worker pool namespaces, as upstream Substrate did. The k3s-level mechanism of ADR 0024 is removed with its only user; the `kagent` subsystem labels the namespaces instead (ADR 0030).

What changes now:

- Our `substrate` subsystem (`backfabric.substrate.*`), its packages, the k3s feature gates and runtime-config it set, `backfabric.k3s.podSecurityExemptions` and `backfabric.k3s.denyUnlistedImages` with the admission policy `backfabric-exempt-namespace-images`, the agent image (`packages.x86_64-linux.agent-image`), its workflow, and the A2A supervisor are removed. A host configuration that sets any of these options no longer evaluates. CI builds only the website (ADR 0026). `backfabric keygen` no longer generates `rustfs-access-key` and `rustfs-secret-key`; fleets set up before may remove both from `secrets/common.yaml` (`sops unset secrets/common.yaml '["rustfs-access-key"]'`, the same for the other).
- Every host restarts k3s once with this change: its `--disable` list loses the three manifests of the removed subsystem and the image policy.
- CloudNativePG (ADR 0025), OpenBao, the Collector, k3s's hardening and the admission policy against NodePort and LoadBalancer Services stay.
- A host that ran Substrate is either reinstalled from scratch or cleaned. To clean it, its configuration lists the removed manifests, `backfabric.k3s.removedManifests = [ "substrate-volumes" "substrate-rustfs" "substrate-rustfs-credentials" "backfabric-exempt-namespace-images" ];`, so that k3s deletes `ate-system` with everything in it, the volumes and the image policy. Before that deployment, while the feature gates are still on, delete Substrate's ClusterTrustBundles (signers `*.podcert.ate.dev/identity`); afterwards they can no longer be listed or deleted. The `ate.dev` CRDs, `podcertificate-controller-system` and `/var/lib/substrate` stay for manual deletion.
