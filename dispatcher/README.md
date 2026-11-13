# The dispatcher

The A2A front door for agent tasks ([ADR 0028](../docs/adr/0028-dispatcher.md)):
every task for an agent enters here, is authenticated, authorized and
committed to the dispatcher's record in PostgreSQL before it is answered.

This version is the intake: it accepts, records and answers tasks
(`SendMessage`, `GetTask`, `CancelTask`). Tasks stay in
`TASK_STATE_SUBMITTED` until turn execution (the queue in Hatchet and the
turn through Substrate) is added; push notifications and the blocking mode
of `SendMessage` come with it.

## Endpoints

| Path | What |
| ---- | ---- |
| `GET /agents/<agent>/.well-known/agent-card.json` | the agent's card, unauthenticated |
| `POST /agents/<agent>/` | A2A 1.0, JSON-RPC binding; the header `A2A-Version: 1.0` is required |
| `GET /healthz` | 200 when the database answers, else 503 (the reason in the log only) |

Methods: `SendMessage`, `GetTask`, `CancelTask`. Streaming and `ListTasks`
answer `UnsupportedOperationError`, the push notification methods
`PushNotificationNotSupportedError`, `GetExtendedAgentCard`
`ExtendedAgentCardNotConfiguredError`.

`SendMessage` always returns at once (as with `returnImmediately: true`),
with the task in `TASK_STATE_SUBMITTED`, once the message and its task are
committed. The message must have a `messageId`, role `ROLE_USER` and text
parts.

- Without `taskId` it starts a task: in the given `contextId` if that
  context is the caller's with this agent (a new `contextId` chosen by the
  caller starts a context), else in a new context.
- With `taskId` it continues the caller's task if the task waits for the
  caller (`TASK_STATE_INPUT_REQUIRED` or `TASK_STATE_AUTH_REQUIRED`); the
  task is `TASK_STATE_SUBMITTED` again. Any other state is
  `UnsupportedOperationError`.
- The same caller sending the same `messageId` again gets the existing task
  and nothing is recorded again, also when both requests race; the same
  `messageId` sent to another agent is `InvalidParamsError`.

A caller sees and cancels only its own tasks with that agent; others' are
`TaskNotFoundError`. `CancelTask` cancels a task that has not finished,
else `TaskNotCancelableError`.

## Authentication and authorization

Every A2A call carries `Authorization: Bearer <JWT>`. The token is verified
in the process (go-oidc): signature against the issuer's published keys
(fetched on first use and again for an unknown key id), `iss` exactly one
of the configured issuers, `aud` that issuer's audience, expiry. The caller
is the issuer's name and the token's `sub`. In the cluster the issuer is
Kubernetes' service account issuer and the token a service account token
for the audience `dispatcher`:

```sh
kubectl create token operator -n operator --audience dispatcher
```

A failed verification is `UnauthenticatedError` (JSON-RPC `-31401`). A
caller not listed in the agent's `callers` is `UnauthorizedError`
(`-31403`), for every method: deny by default.

A message's provenance is recorded with it: the caller, the principal it
acts for, and the channel, from the `SendMessage` request's `metadata`:

| Key | Value |
| --- | ----- |
| `backfabric.io/principal` | whom the caller acts for: one of its configured `principals`, else `UnauthorizedError`; without it, the caller itself |
| `backfabric.io/channel` | the channel the message came through, recorded as stated |

The caller learns only the kind of a refusal: authentication and
authorization errors carry no reason (the reason is in the audit). The
dispatcher's own failures (the database) are logged and answered with
`InternalError`, without details.

The server reads a request within 30 seconds (headers within 10), writes
its answer within a minute, and closes idle connections after two
minutes.

## Configuration

One JSON file, `-config` (default `/etc/dispatcher/config.json`), written
by the NixOS module that deploys the dispatcher. Unknown fields are errors.

```json
{
  "listen": ":8080",
  "url": "http://dispatcher.dispatcher.svc:8080",
  "issuers": {
    "kubernetes": {
      "issuer": "https://kubernetes.default.svc.cluster.local",
      "audience": "dispatcher",
      "jwksURL": "https://kubernetes.default.svc/openid/v1/jwks",
      "caFile": "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
      "tokenFile": "/var/run/secrets/kubernetes.io/serviceaccount/token"
    }
  },
  "audit": {
    "tokenFile": "/var/run/secrets/otel/token"
  },
  "agents": {
    "codex": {
      "description": "Codex in its own sandbox: one session per context.",
      "version": "sha256:<image digest>",
      "skills": [
        {"id": "codex", "name": "Codex", "description": "Reads, writes and runs code.", "tags": ["coding"]}
      ],
      "callers": [
        {"issuer": "kubernetes", "subject": "system:serviceaccount:operator:operator"},
        {"issuer": "kubernetes", "subject": "system:serviceaccount:chat:adapter", "principals": ["alice@example.org"]}
      ]
    }
  }
}
```

| Field | Required | Meaning |
| ----- | -------- | ------- |
| `listen` | yes | the server's address |
| `maxRequestBytes` | no | the largest request body, default 1048576 (1 MiB); a larger one is refused before it is read whole, since a2a-go decodes a request before it is authenticated |
| `url` | yes | the base URL callers use; cards advertise `<url>/agents/<agent>/` |
| `issuers.<name>.issuer` | yes | the exact `iss` claim |
| `issuers.<name>.audience` | yes | the `aud` a token must carry |
| `issuers.<name>.jwksURL` | no | where the keys are; without it, OIDC discovery at `issuer` |
| `issuers.<name>.caFile` | no | the only CA trusted when fetching keys (or discovery) |
| `issuers.<name>.tokenFile` | no | a bearer token sent when fetching keys, read for every fetch (Kubernetes' API server rejects anonymous requests; the service account needs `system:service-account-issuer-discovery`, which Kubernetes grants every service account) |
| `audit.tokenFile` | no | a bearer token sent with every audit export, read for every export |
| `agents.<agent>` | | an agent; `<agent>` is a DNS label |
| `agents.<agent>.description`, `.version` | yes | the card's description and version |
| `agents.<agent>.skills` | no | the card's skills, A2A `AgentSkill` objects |
| `agents.<agent>.callers[]` | no | who may call the agent: `issuer` (a name in `issuers`), `subject`, and `principals` it may act for |

The issuer's keys are fetched from `jwksURL` rather than through discovery
in the cluster: the discovery document of Kubernetes names its JWKS by the
API server's external address. Fetches time out after 10 seconds and do
not follow redirects (the token goes to the configured URL only).

Callers are keyed by the issuer's *name* in `issuers`, not by its `iss`:
renaming an entry makes its callers new callers, whose earlier contexts
and tasks they no longer see and whose `messageId`s are new again. Rename
only together with the record.

## Environment

| Variable | Meaning |
| -------- | ------- |
| `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE`, `PGSSLROOTCERT`, ... | the database, libpq's variables (the Secret `postgres-<database>` of [the platform PostgreSQL](../docs/postgres.md), with `PGSSLMODE=verify-full`) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` (or `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`) | the Collector's OTLP/HTTP endpoint, e.g. `https://otel-collector.otel.svc:4318`; unset: audit events go to the log only |
| `OTEL_EXPORTER_OTLP_CERTIFICATE` | the CA of the Collector (`openbao-ca-cert`, [docs/otel.md](../docs/otel.md)) |

At startup the dispatcher retries connecting to the database every 2
seconds until it answers, then applies its migrations (goose, under a
PostgreSQL advisory lock). It reads `PGSSLROOTCERT` at startup: after
CloudNativePG renews its CA, restart it.

## Audit

One event per decision, as an OpenTelemetry log event (and a log line):
`dispatcher.accepted` (also for a duplicate, with `dispatcher.duplicate`),
`dispatcher.cancelled`, and `dispatcher.refused` with `dispatcher.reason`
for every refused call: unauthenticated, not a caller, a principal the
caller may not act for, an invalid or conflicting message, a task that is
not the caller's or cannot be cancelled, an unsupported method. Only a
request without `A2A-Version: 1.0` is refused before it reaches the
dispatcher's code (by a2a-go), without an event.
Attributes: `dispatcher.agent`, `dispatcher.method`, `a2a.task_id`,
`a2a.context_id`, `a2a.message_id`, `dispatcher.caller.issuer`,
`dispatcher.caller.subject`, `dispatcher.principal`, `dispatcher.channel`.
Message contents stay in the record.

## The record

The schema is in [migrations/](migrations/), applied at startup:

- `contexts`: one per agent session (`contextId`), with its agent and the
  caller that started it;
- `tasks`: one per turn, with its context, state, A2A `TaskStatus` and
  `Artifact`s (JSON);
- `messages`: the messages of each task in order (`seq`), the caller's
  with their provenance (caller, principal, channel), as A2A `Message`s
  (JSON). A unique index on caller and `messageId` makes intake idempotent.

## Build and test

```sh
nix build .#dispatcher                          # runs go vet and the tests
nix build .#packages.x86_64-linux.dispatcher-image   # on Linux; CI builds it
```

The tests that need the record run against a real PostgreSQL: the Nix
build on Linux starts one (nixpkgs' `postgresqlTestHook`) and sets
`DISPATCHER_TEST_DATABASE=required`, so they fail rather than skip without
it; elsewhere they run when `PGHOST` (and the other libpq variables) point
at an empty database, and are skipped otherwise:

```sh
cd dispatcher
PGHOST=/tmp/pg PGUSER=postgres PGDATABASE=dispatcher go test ./...
```

## Published images

CI (`.github/workflows/dispatcher-image.yml`) builds the image on every
pull request that touches it, starts it against a PostgreSQL and checks the
card and a refused call; on main it pushes `ghcr.io/backfabric/dispatcher`
tagged with the commit SHA, with a build provenance attestation. Consumers
pin the digest from the run's summary:

```sh
gh attestation verify oci://ghcr.io/backfabric/dispatcher@<digest> --owner backfabric
```

The image holds the static binary and the CA bundle only, runs as uid
65532 and writes nothing to its file system (`readOnlyRootFilesystem`).
Like the agent image (ADR 0022), the package is private at its first push;
an organization owner makes it public once:
<https://github.com/orgs/backfabric/packages/container/dispatcher/settings>,
"Danger Zone", "Change visibility", "Public".
