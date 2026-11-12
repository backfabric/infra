# Audit telemetry: the OpenTelemetry Collector

Every host runs an [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
next to k3s (`nix/modules/otel.nix`,
[ADR 0021](adr/0021-audit-telemetry-collector-on-host.md)). It receives
OTLP from pods, authenticates every sender, stamps the sender's verified
identity onto the data, masks credentials, and appends everything to an
archive on the host.

The units: `opentelemetry-collector.service` (the Collector, as a dynamic
user) and `otel-jwks.service` (copies the service account issuer's public
keys from the API server, at every deployment and daily).

## Sending

Pods send OTLP over TLS to `otel-collector.otel.svc`, port 4317 (gRPC) or
4318 (HTTP, `/v1/traces`, `/v1/metrics`, `/v1/logs`), and trust the CA
`openbao-ca-cert` of `secrets/common.yaml`. Every request carries
`Authorization: Bearer <token>`, a service account token for the audience
`otel-collector`, from a projected volume (the kubelet renews it):

```yaml
volumes:
  - name: otel-token
    projected:
      sources:
        - serviceAccountToken:
            audience: otel-collector
            expirationSeconds: 3600
            path: token
```

With the OpenTelemetry SDKs, read the file into the header (e.g.
`OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <token>`, refreshed when
the file changes) and set `OTEL_EXPORTER_OTLP_CERTIFICATE` to the CA file.
A request without a token, with a token for another audience, from another
issuer, or expired, is rejected (HTTP 401, gRPC `Unauthenticated`), and the
Collector logs the reason with the client address.

## Identity

The token, not the data, says who sent it. On every resource the
Collector:

- deletes what the sender set in `k8s.*`, `backfabric.*`, `service.name`
  and `service.namespace`;
- sets `backfabric.source.subject` (the token's subject,
  `system:serviceaccount:<namespace>:<service account>`),
  `backfabric.source.namespace`, `backfabric.source.service_account`, and
  `backfabric.source.address` (the connection's peer address, the pod's IP);
- sets `k8s.namespace.name` and `service.namespace` to the namespace and
  `service.name` to the service account, for tools that read the standard
  attributes;
- deletes `backfabric.*` from span, span event, log and data point
  attributes, so nothing below the resource imitates the stamp.

The pod's name is not stamped: the token's pod claim is nested, and the
authenticator exposes only top-level claims. The pod is found by its IP
(`backfabric.source.address`) and the time.

Trust follows the identity: data from the service accounts of the trusted
services (invoker, egress broker, LLM gateway, ...) is the audit of record;
everything else, in particular from agents' service accounts, is what the
agent claims. A container in an agent's pod shares the pod's service
account and is not a separate source.

## Redaction

Masked with `****` before anything is written, in resource, scope, span,
span event, log and data point attributes and in log bodies (strings and
maps):

- attributes whose key contains, as a word (separated by `.`, `_`, `-`),
  `authorization`, `proxy-authorization`, `cookie`, `set-cookie`,
  `x-api-key`, `api-key`/`api_key`/`apikey`, `x-auth-token`,
  `access-token`, `refresh-token`, `id-token`, `token`, `secret`,
  `client-secret`, `password`, `passwd`, `credential(s)`, `private-key` (any
  case): the whole value, also lists such as `http.request.header.cookie`;
- in every other value, the part that matches: `Bearer`/`Basic`
  credentials, JWTs, PEM private keys, `user:password@` in URLs,
  `password=...`, `token: ...` and similar pairs, and the formats of OpenAI
  and Anthropic keys (`sk-...`), GitHub tokens, Slack tokens, Google API
  keys, AWS access key ids, OpenBao tokens and k3s tokens.

A record with masked values gets `redaction.masked.count` (or
`redaction.body.masked.count`). Not covered: span names, status messages,
event names and link attributes; a credential in an unrecognised format.
Senders must not put credentials into telemetry; the masking is the safety
net.

## Archive

`/var/log/otel-collector/` (a link to `/var/log/private/otel-collector`,
which only root can enter; the files are mode 0600):

| File | Content |
| ---- | ------- |
| `traces.jsonl` | spans |
| `metrics.jsonl` | metrics |
| `logs.jsonl` | log records |

Each line is one received request as OTLP JSON (an `ExportTraceServiceRequest`
and so on): nothing is sampled or batched. A file is renamed to
`<signal>-<UTC time>-size.jsonl` at 100 MB, and renamed files are deleted
after 365 days. Read it as root, e.g. the spans of one namespace:

```sh
jq -c '.resourceSpans[]
  | select(any(.resource.attributes[]; .key == "backfabric.source.namespace" and .value.stringValue == "my-ns"))
  | .scopeSpans[].spans[] | {name, startTimeUnixNano}' /var/log/otel-collector/traces.jsonl
```

The archive is append-only as far as the Collector is concerned; root on
the host can still change or delete it. Shipping it off the host is the
answer to that and is not implemented yet (ADR 0021). Watch the disk:
`du -sh /var/log/private/otel-collector`.

## TLS

The certificate is for `otel-collector.otel.svc`,
`otel-collector.otel.svc.cluster.local` and `127.0.0.1`, signed by the CA
of OpenBao's certificate (`openbao-ca-cert`; [openbao.md](openbao.md#tls)),
3 years. On the host:

```sh
openssl s_client -connect 127.0.0.1:4318 -CAfile /run/secrets/openbao-ca-cert </dev/null 2>/dev/null |
  openssl x509 -noout -text | grep -E -A1 'Not After|Subject Alternative Name'
```

To issue a new one, in the dev shell:

```sh
sops unset secrets/common.yaml '["otel-tls-key"]'
sops unset secrets/common.yaml '["otel-tls-cert"]'
backfabric keygen
git commit secrets/ -m "chore: renew the OpenTelemetry Collector's TLS certificate"
backfabric deploy node1
```

## Issuer keys

`otel-jwks` checks that the API server's issuer is
`https://kubernetes.default.svc.cluster.local` and writes its public keys
to `/var/lib/otel-jwks/jwks.json`; the Collector reloads the file when it
changes. If the cluster is down, the Collector keeps the last copy. After
rotating the service account signing key, copy the new keys at once:

```sh
systemctl start otel-jwks
journalctl -u otel-jwks -n 20
```

If the Collector logs `token verification failed` for valid tokens, compare
the `kid` of the token with the keys in the file.

## Troubleshooting

```sh
systemctl status opentelemetry-collector otel-jwks
journalctl -u opentelemetry-collector -n 50
ss -tlnp | grep -E ':431[78]'
```

The Collector listens on 127.0.0.1 and the node address; the firewall
opens 4317 and 4318 only on `cni0`. When memory use passes 400 MiB, it
refuses data with a retryable error (the sender's exporter retries);
systemd stops it at 512 MiB.
