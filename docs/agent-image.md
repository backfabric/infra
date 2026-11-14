# The agent image

`ghcr.io/backfabric/agent` is the container image of an agent, run as an
[Agent Substrate](https://github.com/agent-substrate/substrate) actor: one
actor per agent session (one [A2A](https://a2a-protocol.org/) context),
suspended between tasks and resumed when a request arrives. It serves A2A
1.0. It is built with Nix (`nix/images/agent.nix`,
`packages.x86_64-linux.agent-image`) and published by CI
([ADR 0022](adr/0022-ci-builds-the-agent-image.md)). It contains no secrets,
and neither does the actor: Codex reaches the OpenAI API with a placeholder
key that Substrate's egress gateway replaces with the real one
([model access](#model-access),
[ADR 0030](adr/0030-egress-injected-model-keys.md)).

## Contents

- [Codex](https://github.com/openai/codex) from its release package
  (`codex-package-x86_64-unknown-linux-musl.tar.gz`, what upstream's
  `install.sh` installs): the static `codex` with its helpers (code mode
  host, exec server, `rg`, `bwrap`).
- The supervisor `agent/supervisor.py`, the entrypoint: the
  [A2A Python SDK](https://github.com/a2aproject/a2a-python) 1.x
  (`nix/packages/a2a-sdk.nix`; nixpkgs has 0.3.x, which speaks A2A 0.3) and
  uvicorn, on `python3`.
- bash, coreutils, findutils, grep, sed, diffutils, git (`gitMinimal`), the
  CA certificates (`SSL_CERT_FILE`), `/usr/bin/env`, `/tmp`.

| Config | Value |
| ------ | ----- |
| User | `1000:1000` (`agent`) |
| WorkingDir, `HOME` | `/home/agent` |
| `CODEX_HOME` | `/home/agent/.codex` |
| Entrypoint | `python3 -u /nix/store/<hash>-supervisor.py`: `agent/supervisor.py` copied into the Nix store, run by a Python with the A2A SDK and uvicorn |
| Port | 8080 |

The supervisor listens on 8080, not 80: a non-root process in a Substrate
actor has no effective capabilities (no `NET_BIND_SERVICE`; ambient
capabilities are not supported), so it cannot bind ports below 1024.
Substrate's router sends requests to port 80 by default, so the
ActorTemplate and the clients must name 8080:

- `wakeupProbe: {httpGet: {path: /healthz, port: 8080}}`;
- `kubectl ate proxy actor <actor> 8000:8080 -a <atespace>`; other clients
  reach the port with an HTTP `CONNECT <actor-dns>:8080` through the router.

### State

The home directory is the agent's state: Codex's configuration and sessions
in `/home/agent/.codex`, the id of the actor's Codex session in
`/home/agent/codex-session`, the contextId it serves in
`/home/agent/a2a-context`, the tasks' working directory `/home/agent/work`.
Snapshots of fidelity `SNAPSHOT_FIDELITY_MEMORY` or `ROOTFS` keep it across
a suspend; mount a `durableDir` volume at `/home/agent` so it also survives
a restore of volumes only. The snapshots hold the conversation and its
files, but no credential: the actor has only the placeholder.

The A2A tasks are kept in memory only: a restore of volumes only, or a
restart, forgets them, not the session. The caller (the platform's
dispatcher) holds the canonical record of every message, task and artifact;
the actor is its working copy.

## Model access

Codex sends its requests to `https://api.openai.com/v1` (the Responses API)
with `Authorization: Bearer <AGENT_OPENAI_API_KEY>`, a placeholder.
Substrate's egress gateway terminates the actor's TLS for `api.openai.com`,
replaces the header with the real OpenAI API key from a Kubernetes Secret,
and sends the request on
([egress credential injection](https://github.com/agent-substrate/substrate/blob/v1.0.0/docs/guides/egress-credential-injection.md)).
The key never enters the actor, its environment or its snapshots, and no
one logs an actor in. The gateway's credential provider, the Secret and
agent-0's ActorTemplate and EgressPolicy: [Agent Substrate](substrate.md).
Why an API key and not the ChatGPT subscription:
[ADR 0030](adr/0030-egress-injected-model-keys.md).

The ActorTemplate sets (the image sets neither):

| Variable | Value |
| -------- | ----- |
| `AGENT_OPENAI_API_KEY` | A placeholder, e.g. `injected-by-egress`; Codex sends it as the bearer token. Required: without it, or empty, the supervisor logs `{"error": "no_api_key", ...}` and exits 1. |
| `CODEX_CA_CERTIFICATE` | `/run/ate/egress-trust-bundle/trust-bundle.pem`: Codex's own variable for the CA bundle it trusts, here the gateway's CA and the public roots from a `systemInfo` volume. Other tools keep the image's `SSL_CERT_FILE`: only Codex's traffic is intercepted. |

```yaml
containers:
- name: agent
  image: ghcr.io/backfabric/agent@sha256:<digest>
  env:
  - name: AGENT_OPENAI_API_KEY
    value: injected-by-egress
  - name: CODEX_CA_CERTIFICATE
    value: /run/ate/egress-trust-bundle/trust-bundle.pem
  volumeMounts:
  - name: system-info
    mountPath: /run/ate/egress-trust-bundle
volumes:
- name: system-info
  systemInfo:
    dataSources:
    - trustBundle:
        names:
        - egress-mitm.ate.dev   # the egress gateway's CA
        - system-roots.ate.dev  # public roots
        path: trust-bundle.pem
```

The actor's EgressPolicy rule, with the key under `<key>` in the Secret
`<secret>` of namespace `<namespace>` (`default` is the only locator of
Substrate's Kubernetes Secrets provider; [Agent Substrate](substrate.md)
names the ones the `substrate` subsystem creates):

```yaml
rules:
- https:
    hostnames: ["api.openai.com"]
    effects:
      replaceHeaders:
      - header: Authorization
        prefix: "Bearer "
        credentialUri: ate-secret://k8s.io/default/<namespace>/<secret>/<key>
```

At every start the supervisor writes `/home/agent/.codex/config.toml` (only
when it differs; the file is the supervisor's, edits are overwritten):

```toml
model_provider = "openai-api"

[features]
unbounded_connection_retries = false

[model_providers.openai-api]
name = "OpenAI API"
base_url = "https://api.openai.com/v1"
wire_api = "responses"
env_key = "AGENT_OPENAI_API_KEY"
supports_websockets = false
```

- A custom provider, not Codex's built-in `openai` with `CODEX_API_KEY`: the
  built-in provider opens a Responses WebSocket first and falls back to
  HTTPS only on `426 Upgrade Required`, while the egress gateway refuses
  every WebSocket upgrade with `403`
  ([egress traffic](https://github.com/agent-substrate/substrate/blob/v1.0.0/docs/guides/egress-traffic.md)),
  and built-in providers cannot be overridden. The custom provider speaks
  HTTPS only (`supports_websockets = false`) and sends `env_key`'s value as
  the bearer token; Codex does not check the key itself.
- `unbounded_connection_retries = false`: by default Codex retries an
  unreachable API until the task is killed (`AGENT_TASK_TIMEOUT`); without
  it a turn fails after Codex's 5 retries, so a missing egress rule or a
  gateway outage is a `codex_failed` (`Connection failed: ...`) within
  about half a minute.
- Codex's default model; there is no override.

## Supervisor API

No authentication: only Substrate's router can reach the actor. Every
request is logged as one JSON line on stdout, as is every task (its state)
and every Codex turn (session, error).

| Request | Response |
| ------- | -------- |
| `GET /.well-known/agent-card.json` | The A2A agent card: one JSON-RPC interface, A2A 1.0, at the URL the card was fetched from; no streaming, no push notifications; text in and out. |
| `POST /` | A2A 1.0 JSON-RPC: `SendMessage`, `GetTask`, `CancelTask`. Requests carry the header `A2A-Version: 1.0`; without it the SDK assumes 0.3 and answers `VersionNotSupportedError`. |
| `GET /healthz` | 200 `{"ok": true}` |

### Sessions

One actor is one agent session, one A2A context. The first message records
its contextId (or the one the SDK generates when it has none) in
`/home/agent/a2a-context`; any later message with another contextId, or with
none, is rejected with `InvalidParamsError` (`-32602`): a new conversation
gets a new actor. Messages without a text part are rejected the same way.

The first message that reaches Codex starts a Codex session (`codex exec`);
the supervisor records its id (`thread_id` of the `thread.started` event) in
`/home/agent/codex-session` as soon as Codex reports it, while the turn
runs, so it stays even if that turn fails, times out, is canceled or the
actor restarts. Every later message
continues it (`codex exec resume <session>`) with only the new text, so Codex
sees the earlier messages, answers and commands. If Codex no longer has the
recorded session (its rollout under `/home/agent/.codex/sessions` is gone),
every task fails with `no rollout found for thread id ...`; the supervisor
does not silently start a new one.

One task at a time: a `SendMessage` while Codex works on a task is rejected
with `UnsupportedOperationError` (`-32004`, naming the running task).

### Tasks

Each message starts a new task. A message that names a `taskId` is
rejected: `UnsupportedOperationError` (`-32004`) for an ended task,
`TaskNotFoundError` for an unknown one. `SendMessage` blocks until the task
ends unless the request sets `configuration.returnImmediately: true`; then
it returns the task at once, in `TASK_STATE_WORKING`, and the caller polls
`GetTask`.

| Outcome | Task state | Content |
| ------- | ---------- | ------- |
| Codex answered | `TASK_STATE_COMPLETED` | Artifact `response`: Codex's final message as one text part |
| Codex exited nonzero | `TASK_STATE_FAILED` | Status message `codex_failed: <why>` (Codex's `turn.failed` message, else the end of its stderr), metadata `{"error": "codex_failed"}` |
| Killed after `AGENT_TASK_TIMEOUT` seconds (environment, default 3600), with every process it started | `TASK_STATE_FAILED` | `timeout: ...`, metadata `{"error": "timeout"}` |
| `CancelTask` | `TASK_STATE_CANCELED` | Codex and its processes are killed. |

`codex exec` runs with `--dangerously-bypass-approvals-and-sandbox` (no
approval prompts, no Codex sandbox: the actor's gVisor sandbox is the
boundary; Codex's own Linux sandbox, bubblewrap in user namespaces, would be
a second one, untested under gVisor), `--skip-git-repo-check`, `--color
never`, `--json` and the message's text on stdin, with the configuration
from [model access](#model-access).

### Example

Through `kubectl ate proxy actor <actor> 8000:8080 -a <atespace>`:

```sh
curl -s localhost:8000/.well-known/agent-card.json

a2a() {
  curl -s localhost:8000/ -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -d "$1"
}

# Blocking: returns when the task ends.
a2a '{"jsonrpc": "2.0", "id": 1, "method": "SendMessage", "params": {
  "message": {"role": "ROLE_USER", "messageId": "m1", "contextId": "c1",
    "parts": [{"text": "Say hello"}]}}}'
# -> .result.task.status.state "TASK_STATE_COMPLETED",
#    .result.task.artifacts[0].parts[0].text the answer

# Non-blocking: returns the task in TASK_STATE_WORKING; poll GetTask.
a2a '{"jsonrpc": "2.0", "id": 2, "method": "SendMessage", "params": {
  "message": {"role": "ROLE_USER", "messageId": "m2", "contextId": "c1",
    "parts": [{"text": "What did I ask you before?"}]},
  "configuration": {"returnImmediately": true}}}'
a2a '{"jsonrpc": "2.0", "id": 3, "method": "GetTask", "params": {"id": "<task id>"}}'
a2a '{"jsonrpc": "2.0", "id": 4, "method": "CancelTask", "params": {"id": "<task id>"}}'
```

## Published images

Every push to main that changes `agent/`, `nix/images/`,
`nix/packages/a2a-sdk.nix`, `flake.nix` or `flake.lock`
(and every manual run of the workflow `agent-image`) publishes the image
tagged with the full commit SHA; there is no `latest`. The digest is in the
run's summary (Actions, workflow `agent-image`, the run of the commit), or:

```sh
skopeo inspect --format '{{.Digest}}' docker://ghcr.io/backfabric/agent:<commit>
```

Pin it by digest, `ghcr.io/backfabric/agent@sha256:...`, and verify its build
provenance (built by this repository's workflow, from which commit):

```sh
gh attestation verify oci://ghcr.io/backfabric/agent@sha256:... --owner backfabric
```

The package must be public for the cluster to pull it anonymously. A package
published by a workflow starts private; an organization owner makes it public
once: <https://github.com/orgs/backfabric/packages/container/agent/settings>,
"Danger Zone", "Change visibility", "Public" (irreversible). Check without
credentials:

```sh
skopeo inspect --no-creds docker://ghcr.io/backfabric/agent:<commit>
```

## Bumping Codex

1. Pick the release at <https://github.com/openai/codex/releases>
   (`rust-v<version>`) and read the asset digest of
   `codex-package-x86_64-unknown-linux-musl.tar.gz`:

   ```sh
   gh release view rust-v<version> -R openai/codex --json assets \
     --jq '.assets[] | select(.name == "codex-package-x86_64-unknown-linux-musl.tar.gz") | .digest'
   nix hash convert --hash-algo sha256 --to sri <hex digest>
   ```

2. Optionally verify the archive against the release's Sigstore bundle:

   ```sh
   gh release download rust-v<version> -R openai/codex \
     -p codex-package-x86_64-unknown-linux-musl.tar.gz -p codex-package-x86_64-unknown-linux-musl.tar.gz.sigstore
   cosign verify-blob --bundle codex-package-x86_64-unknown-linux-musl.tar.gz.sigstore \
     --certificate-identity https://github.com/openai/codex/.github/workflows/rust-release.yml@refs/tags/rust-v<version> \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     codex-package-x86_64-unknown-linux-musl.tar.gz
   ```

3. Set `version` and `hash` in `nix/images/agent.nix`, check `codex exec
   --help`, `codex exec resume --help`, the `--json` events
   (`thread.started`, `turn.failed`), the provider keys of `config.toml`
   (`env_key`, `wire_api`, `supports_websockets`), the CA variable
   `CODEX_CA_CERTIFICATE` and the feature `unbounded_connection_retries` of
   the new version against what the supervisor uses, and open a PR: its CI
   builds the image, the merge publishes it.
