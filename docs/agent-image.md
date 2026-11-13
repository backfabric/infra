# The agent image

`ghcr.io/backfabric/agent` is the container image of an agent, run as an
[Agent Substrate](https://github.com/agent-substrate/substrate) actor: one
actor per agent session (one [A2A](https://a2a-protocol.org/) context),
suspended between tasks and resumed when a request arrives. It serves A2A
1.0. It is built with Nix (`nix/images/agent.nix`,
`packages.x86_64-linux.agent-image`) and published by CI
([ADR 0022](adr/0022-ci-builds-the-agent-image.md)). It contains no secrets:
each agent logs in to Codex with the user's ChatGPT subscription at run time.

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

The home directory is the agent's state: Codex's login (`auth.json`),
configuration and sessions in `/home/agent/.codex`, the id of the actor's
Codex session in `/home/agent/codex-session`, the contextId it serves in
`/home/agent/a2a-context`, the tasks' working directory `/home/agent/work`.
Snapshots of fidelity `SNAPSHOT_FIDELITY_MEMORY` or `ROOTFS` keep it across
a suspend; mount a `durableDir` volume at `/home/agent` so it also survives
a restore of volumes only. The snapshots therefore hold the agent's Codex
login: whoever can read the snapshot storage can use the subscription.

The A2A tasks are kept in memory only: a restore of volumes only, or a
restart, forgets them, not the session. The caller (the platform's
dispatcher) holds the canonical record of every message, task and artifact;
the actor is its working copy.

## Supervisor API

No authentication: only Substrate's router can reach the actor. Every
request is logged as one JSON line on stdout, as is every task (its state)
and every Codex turn (session, error).

| Request | Response |
| ------- | -------- |
| `GET /.well-known/agent-card.json` | The A2A agent card: one JSON-RPC interface, A2A 1.0, at the URL the card was fetched from; no streaming, no push notifications; text in and out. |
| `POST /` | A2A 1.0 JSON-RPC: `SendMessage`, `GetTask`, `CancelTask`. Requests carry the header `A2A-Version: 1.0`; without it the SDK assumes 0.3 and answers `VersionNotSupportedError`. |
| `GET /healthz` | 200 `{"ok": true}` |
| `POST /login` | Starts `codex login --device-auth` and returns as soon as Codex prints the code: 200 `{"verification_url", "user_code"}`. Open the URL, enter the code; the login completes in the background. While it runs, another `POST /login` returns the same code. 502 with Codex's output if it printed none within 30 seconds. |
| `GET /login` | 200 `{"logged_in", "status", "login_running"}` from `codex login status` |

`/login` is not A2A: logging an agent in to the ChatGPT subscription is an
operator action, done once per actor through `kubectl ate proxy`, never by a
caller of the agent.

### Sessions

One actor is one agent session, one A2A context. The first message records
its contextId (or the one the SDK generates when it has none) in
`/home/agent/a2a-context`; any later message with another contextId, or with
none, is rejected with `InvalidParamsError` (`-32602`): a new conversation
gets a new actor. A follow-up that names its `taskId` but no contextId
takes the task's. Messages without a text part are rejected the same way.

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

Each message starts a new task, or continues the task it names (`taskId`)
while that task waits in `TASK_STATE_AUTH_REQUIRED`. `SendMessage` blocks
until the task ends unless the request sets
`configuration.returnImmediately: true`; then it returns the task at once,
in `TASK_STATE_WORKING`, and the caller polls `GetTask`.

| Outcome | Task state | Content |
| ------- | ---------- | ------- |
| Codex answered | `TASK_STATE_COMPLETED` | Artifact `response`: Codex's final message as one text part |
| Codex exited nonzero | `TASK_STATE_FAILED` | Status message `codex_failed: <why>` (Codex's `turn.failed` message, else the end of its stderr), metadata `{"error": "codex_failed"}` |
| Killed after `AGENT_TASK_TIMEOUT` seconds (environment, default 3600), with every process it started | `TASK_STATE_FAILED` | `timeout: ...`, metadata `{"error": "timeout"}` |
| Not logged in to ChatGPT (`codex login status`); Codex did not run | `TASK_STATE_AUTH_REQUIRED` | `Codex is not logged in ...`, metadata `{"error": "needs_login"}`. After the login, send the message again, to the same task or a new one. |
| `CancelTask` | `TASK_STATE_CANCELED` | Codex and its processes are killed. |

`codex exec` runs with `--dangerously-bypass-approvals-and-sandbox` (no
approval prompts, no Codex sandbox: the actor's gVisor sandbox is the
boundary; Codex's own Linux sandbox, bubblewrap in user namespaces, would be
a second one, untested under gVisor), `--skip-git-repo-check`, `--color
never`, `--json`, the message's text on stdin, and `--disable
unbounded_connection_retries`: by default Codex retries an unreachable
backend until the task is killed; without it a turn fails after Codex's 5
retries, so a missing egress rule or an outage is a `codex_failed`
(`Connection failed: ...`) within about half a minute.

### Example

Through `kubectl ate proxy actor <actor> 8000:8080 -a <atespace>`:

```sh
curl -s -X POST localhost:8000/login     # open verification_url, enter user_code
curl -s localhost:8000/login             # "logged_in": true once done
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
   --help`, `codex exec resume --help`, `codex login --help`, the `--json`
   events (`thread.started`, `turn.failed`) and the feature
   `unbounded_connection_retries` of the new version against what the
   supervisor uses, and open a PR: its CI builds the image, the merge
   publishes it.
