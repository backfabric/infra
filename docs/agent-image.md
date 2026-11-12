# The agent image

`ghcr.io/backfabric/agent` is the container image of an agent, run as an
[Agent Substrate](https://github.com/agent-substrate/substrate) actor: one
long-lived actor per agent, suspended between tasks and resumed when a
request arrives. It is built with Nix (`nix/images/agent.nix`,
`packages.x86_64-linux.agent-image`) and published by CI
([ADR 0022](adr/0022-ci-builds-the-agent-image.md)). It contains no secrets:
each agent logs in to Codex with the user's ChatGPT subscription at run time.

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

The home directory is the agent's state: Codex's login (`auth.json`),
configuration and sessions in `/home/agent/.codex`, the tasks' working
directory `/home/agent/work`. Snapshots of fidelity `SNAPSHOT_FIDELITY_MEMORY`
or `ROOTFS` keep it across a suspend; mount a `durableDir` volume at
`/home/agent` so it also survives a restore of volumes only. The snapshots
therefore hold the agent's Codex login: whoever can read the snapshot
storage can use the subscription.

## Supervisor API

No authentication: only Substrate's router can reach the actor. Every
response is JSON; every request is logged as one JSON line on stdout.

| Request | Response |
| ------- | -------- |
| `GET /healthz` | 200 `{"ok": true}` |
| `POST /login` | Starts `codex login --device-auth` and returns as soon as Codex prints the code: 200 `{"verification_url", "user_code"}`. Open the URL, enter the code; the login completes in the background. While it runs, another `POST /login` returns the same code. 502 with Codex's output if it printed none within 30 seconds. |
| `GET /login` | 200 `{"logged_in", "status", "login_running"}` from `codex login status` |
| `POST /task` `{"prompt": "..."}` | Runs `codex exec` in `/home/agent/work` and returns when it ends: 200 `{"exit_code", "timed_out", "final_message", "stderr_tail"}` (a failed task is a nonzero `exit_code`, not an HTTP error). 409 while another task runs, 400 without a prompt. |

`codex exec` runs with `--dangerously-bypass-approvals-and-sandbox` (no
approval prompts, no Codex sandbox: the actor's gVisor sandbox is the
boundary; Codex's own Linux sandbox, bubblewrap in user namespaces, would be
a second one, untested under gVisor), `--skip-git-repo-check`, `--color
never`, the prompt on stdin. A task is killed with every process it started
after `AGENT_TASK_TIMEOUT` seconds (environment, default 3600), with
`"timed_out": true`.

Through `kubectl ate proxy actor <actor> 8000:8080 -a <atespace>`:

```sh
curl -s -X POST localhost:8000/login     # open verification_url, enter user_code
curl -s localhost:8000/login             # "logged_in": true once done
curl -s -X POST localhost:8000/task -d '{"prompt": "Say hello"}'
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
   --help` and `codex login --help` of the new version against the flags the
   supervisor uses, and open a PR: its CI builds the image, the merge
   publishes it.
