# The agent image

`ghcr.io/backfabric/agent` is the container image of an agent, run as an
[Agent Substrate](https://github.com/agent-substrate/substrate) actor: one
long-lived actor per agent, suspended between tasks and resumed when a
request arrives. It is built with Nix (`nix/images/agent.nix`,
`packages.x86_64-linux.agent-image`) and published by CI
([ADR 0022](adr/0022-ci-builds-the-agent-image.md)). It contains no secrets.
An agent reaches the model in one of two [modes](#modes), chosen by its
environment: an OpenAI API key that Substrate's egress gateway puts into its
requests, so the agent never holds it, or the user's ChatGPT subscription,
logged in at run time.

## Contents

- [Codex](https://github.com/openai/codex) from its release package
  (`codex-package-x86_64-unknown-linux-musl.tar.gz`, what upstream's
  `install.sh` installs): the static `codex` with its helpers (code mode
  host, exec server, `rg`, `bwrap`).
- The supervisor `nix/images/supervisor.py` (Python 3 standard library, on
  `python3Minimal`), the entrypoint.
- bash, coreutils, findutils, grep, sed, diffutils, git (`gitMinimal`), the
  CA certificates (`SSL_CERT_FILE`), `/usr/bin/env`, `/tmp`.

| Config | Value |
| ------ | ----- |
| User | `1000:1000` (`agent`) |
| WorkingDir, `HOME` | `/home/agent` |
| `CODEX_HOME` | `/home/agent/.codex` |
| Entrypoint | `python3 -u supervisor.py` |
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

The home directory is the agent's state: Codex's configuration, login
(`auth.json`, ChatGPT mode) and sessions in `/home/agent/.codex`, the
supervisor's thread index `/home/agent/threads.json`, the tasks' working
directory `/home/agent/work`. Snapshots of fidelity `SNAPSHOT_FIDELITY_MEMORY`
or `ROOTFS` keep it across a suspend; mount a `durableDir` volume at
`/home/agent` so it also survives a restore of volumes only. In ChatGPT mode
the snapshots therefore hold the agent's Codex login: whoever can read the
snapshot storage can use the subscription. In API-key mode they hold only
the placeholder.

## Modes

| Environment | Mode |
| ----------- | ---- |
| `AGENT_OPENAI_API_KEY` set, not empty | API key through the egress gateway |
| otherwise | ChatGPT login |

The supervisor reports the mode in its first log line and in `GET /login`.

### API key through the egress gateway

The actor sends its requests to `https://api.openai.com/v1` (the Responses
API) with `Authorization: Bearer <AGENT_OPENAI_API_KEY>`, a placeholder.
Substrate's egress gateway terminates the actor's TLS for `api.openai.com`,
replaces the header with the real key from a Kubernetes Secret, and sends the
request on
([egress credential injection](https://github.com/agent-substrate/substrate/blob/v1.0.0/docs/guides/egress-credential-injection.md)).
The key never enters the actor, its environment or its snapshots.

| Variable | Value |
| -------- | ----- |
| `AGENT_OPENAI_API_KEY` | Any placeholder, e.g. `injected-by-egress-gateway`. Selects the mode; Codex sends it as the bearer token. |
| `CODEX_CA_CERTIFICATE` | `/run/ate/egress-trust-bundle/trust-bundle.pem`: Codex's own variable for the CA bundle it trusts, here the gateway's CA and the public roots, from the `systemInfo` volume below. |

At start the supervisor writes `/home/agent/.codex/config.toml` (only when it
differs; it removes the file again when started in ChatGPT mode, and only
the file it wrote):

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
  built-in provider opens a Responses WebSocket first and falls back to HTTPS
  only on `426`, while Substrate's egress gateway refuses WebSocket upgrades
  with `403`. A custom provider uses HTTPS only (`supports_websockets`).
- `unbounded_connection_retries = false`: by default Codex retries an
  unreachable API until the task is killed (`AGENT_TASK_TIMEOUT`); without it
  a task fails after Codex's 5 retries, so a missing egress rule or a gateway
  outage is a `codex_failed` within about half a minute.
- Codex's default model (`gpt-6.1-sol` in 0.167.2).

Prerequisites on the cluster:

- The egress gateway installed with the Kubernetes Secrets credential
  provider (`--credential-provider='{"name":"k8s.io"}'`, which also deploys
  the provider). The `substrate` subsystem
  ([PR #48](https://github.com/backfabric/infra/pull/48)) installs Substrate
  with egress credential injection off; turning it on is a separate change.
  Without a provider the gateway denies the request (`500`/`403`).
- The Secret with the key, in a namespace the provider's policy (ConfigMap
  `ate-system/k8s-credential-provider-namespace-policy`) grants to the
  agent's atespace; the provider reads the policy only at start (`kubectl -n
  ate-system rollout restart deployment/k8s-credential-provider`).

The ActorTemplate (`kubectl ate create actor-template -f`):

```yaml
metadata:
  atespace: <atespace>
  name: <template>
containers:
- name: agent
  image: ghcr.io/backfabric/agent@sha256:<digest>
  env:
  - name: AGENT_OPENAI_API_KEY
    value: injected-by-egress-gateway
  - name: CODEX_CA_CERTIFICATE
    value: /run/ate/egress-trust-bundle/trust-bundle.pem
  volumeMounts:
  - name: system-info
    mountPath: /run/ate/egress-trust-bundle
  wakeupProbe:
    httpGet:
      path: /healthz
      port: 8080
volumes:
- name: system-info
  systemInfo:
    dataSources:
    - trustBundle:
        names:
        - egress-mitm.ate.dev   # the egress gateway's CA
        - system-roots.ate.dev  # public roots
        path: trust-bundle.pem
resources:
  limits:
    cpuMillicores: 1000
    memoryBytes: 1073741824
snapshotConfig:
  preferredFidelity: SNAPSHOT_FIDELITY_MEMORY
```

The actor's EgressPolicy (`kubectl ate create egress-policy <actor> -a
<atespace> -f policy.yaml`), with the Secret `<secret>` in namespace
`<namespace>` holding the key under `<key>`:

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

`default` is the provider's only locator (local Secrets). The actor resolves
only the hostnames its policy names, so `api.openai.com` is the only host it
reaches.

### ChatGPT login

Without `AGENT_OPENAI_API_KEY`, each agent logs in once with the user's
ChatGPT subscription (`POST /login`, device code); Codex keeps and refreshes
the login in `auth.json`.

## Supervisor API

No authentication: only Substrate's router can reach the actor. Every
response is JSON; every request is logged as one JSON line on stdout.

| Request | Response |
| ------- | -------- |
| `GET /healthz` | 200 `{"ok": true}` |
| `GET /login` | API key: 200 `{"mode": "api_key", "login_needed": false}`. ChatGPT: 200 `{"mode": "chatgpt", "login_needed", "logged_in", "status", "login_running"}` from `codex login status`. |
| `POST /login` | ChatGPT: starts `codex login --device-auth` and returns as soon as Codex prints the code: 200 `{"verification_url", "user_code"}`. Open the URL, enter the code; the login completes in the background. While it runs, another `POST /login` returns the same code. 502 with Codex's output if it printed none within 30 seconds. API key: 409, no login needed. |
| `POST /task` `{"prompt": "...", "thread": "..."}` | Runs Codex in `/home/agent/work` and returns when it ends, 200 (a failed task is an `error`, not an HTTP error). 409 while another task runs, 400 without a prompt. |

`thread` is optional: any non-empty string the caller chooses, such as an
email thread's id. The first task of a thread starts a Codex session (`codex
exec`) and the supervisor records its id for the thread in
`/home/agent/threads.json`, even if the task fails; later tasks of the thread
continue it (`codex exec resume <session>`), so Codex sees the earlier
prompts, answers and commands. A task without `thread` starts a session of
its own. The task's response:

| Field | Value |
| ----- | ----- |
| `thread` | The request's `thread`, or `null` |
| `session` | Codex's session id (`thread_id` of its `thread.started` event), `null` if Codex started none |
| `error` | `null` on success; `needs_login` (ChatGPT mode, not logged in: Codex did not run), `timeout` (killed after `AGENT_TASK_TIMEOUT`), `codex_failed` (Codex exited nonzero) |
| `exit_code` | Codex's exit status (negative: killed by that signal), `null` if it did not run |
| `message` | Why it failed: Codex's `turn.failed` message, else its stderr; e.g. `unexpected status 401 Unauthorized: ...` from the API |
| `final_message` | Codex's last message, the answer |
| `stderr_tail` | The end of Codex's stderr |

A thread whose session Codex no longer has (its home was lost) fails with
`codex_failed` and `no rollout found for thread id ...`.

Codex runs with `--dangerously-bypass-approvals-and-sandbox` (no approval
prompts, no Codex sandbox: the actor's gVisor sandbox is the boundary;
Codex's own Linux sandbox, bubblewrap in user namespaces, would be a second
one, untested under gVisor), `--skip-git-repo-check`, `--color never`,
`--json`, the prompt on stdin. A task is killed with every process it started
after `AGENT_TASK_TIMEOUT` seconds (environment, default 3600).

Through `kubectl ate proxy actor <actor> 8000:8080 -a <atespace>`:

```sh
curl -s localhost:8000/login             # mode; in ChatGPT mode "logged_in"
curl -s -X POST localhost:8000/login     # ChatGPT mode: open verification_url, enter user_code
curl -s -X POST localhost:8000/task -d '{"prompt": "Say hello", "thread": "t1"}'
curl -s -X POST localhost:8000/task -d '{"prompt": "What did I ask?", "thread": "t1"}'
```

## Published images

Every push to main that changes `nix/images/`, `flake.nix` or `flake.lock`
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
   --help`, `codex exec resume --help`, `codex login --help` and the `--json`
   events (`thread.started`, `turn.failed`) of the new version against what
   the supervisor uses, and its configuration keys (`model_providers`,
   `features.unbounded_connection_retries`) against the configuration
   reference, and open a PR: its CI builds the image, the merge publishes it.
