# Audit telemetry: OTel Collector on the host

The workloads' telemetry (traces, metrics, logs over OTLP) is collected by an OpenTelemetry Collector that runs on the host, next to OpenBao (ADR 0009), not in the cluster: out of the agents' reach, and working while the cluster is not. Its first output is an append-only audit archive in files on the host; a UI (Langfuse) follows as a second exporter of the same pipeline.

Sources are not equal. Agents are always untrusted: what they report about themselves is a claim. Trusted sources are the services outside the agents' reach (the invoker, the egress broker, the LLM gateway, capability services); their events are the audit of record. To tell them apart, the Collector must know who sent each request, independently of what the request says:

- Every sender authenticates with a Kubernetes service account token projected for the audience `otel-collector`. The Collector verifies it with its OIDC authenticator (`oidcauthextension`) against k3s's service account issuer, `https://kubernetes.default.svc.cluster.local`. OIDC discovery does not work from the host (the issuer's name resolves only in the cluster, and the API server rejects anonymous requests), so a bounded oneshot copies the issuer's public keys (`/openid/v1/jwks`, with the admin kubeconfig) into a file the authenticator reads (`public_keys_file`) and reloads on change, at every deployment and daily. The Collector keeps working with the last copy when the cluster is down.
- The source identity comes from the authentication: the token's subject (`system:serviceaccount:<namespace>:<account>`) and the connection's peer address are written into the resource attributes (`backfabric.source.*`, and `k8s.namespace.name`, `service.namespace`, `service.name`), after deleting whatever the sender put there (`k8s.*`, `backfabric.*`, `service.*` identity); `backfabric.*` is also removed below the resource.
- TLS on the listeners, as for OpenBao (ADR 0019): the bearer tokens never travel in clear text, even on `cni0`. The certificate is for the fixed name `otel-collector.otel.svc` and 127.0.0.1, signed by the existing CA and issued by `backfabric keygen`; the CA key stays in `secrets/admin.yaml`. Pods reach the Collector through a Service without selector whose EndpointSlice points at the node address; ports 4317 and 4318 are open only on `cni0`.
- Credentials never reach the archive: the redaction processor masks attributes with credential-like keys (authorization, cookie, API keys, tokens, secrets, passwords) and values in common credential formats, in attributes and log bodies.
- The archive is OTLP JSON lines, one file per signal, in `/var/log/otel-collector` (root only, files 0600), everything that arrives (no sampling, no batching), rotated at 100 MB and kept 365 days.

The distribution is upstream's `otelcol-k8s` (nixpkgs `opentelemetry-collector-releases.otelcol-k8s`), which has every component used here and fewer others than `otelcol-contrib`.

## Considered Options

- Collector in the cluster: it would share the agents' failure domain and the cluster's administrators; an agent able to influence the cluster could influence its own audit, and an unhealthy cluster would stop the audit.
- Trusting sender-supplied attributes (`k8s.namespace.name`, `service.name`): any agent could claim to be a trusted service.
- The `k8sattributes` processor, identifying the pod by its source IP: no authentication, and it needs API credentials on the host for watching pods; PSA `restricted` drops `NET_RAW`, so pods cannot easily spoof addresses, but the token proves the identity directly.
- Token review against the API server for every request: no such authenticator exists in the Collector distributions; the OIDC authenticator verifies the token's signature, issuer, audience and expiry locally.
- OIDC discovery with the issuer made reachable (`--service-account-issuer` changed to a host-resolvable URL, or anonymous access to the discovery endpoints): changes the cluster's hardening (ADR 0017) and every existing token's issuer.
- A separate CA for the Collector: one more CA key for the admins to keep, with no gain; clients already trust `openbao-ca-cert`.

## Consequences

- Trust is per service account. A trusted service needs its own service account (and pod); a sidecar in an agent's pod shares the agent's account and is indistinguishable from it.
- Tokens are verified offline: a token stays valid until it expires even if its pod is deleted (projected tokens: one hour by default). The pod's name is not stamped (the authenticator exposes only top-level claims); the pod's IP is.
- A new service account signing key reaches the Collector at the next `otel-jwks` run (deployment, daily, or by hand).
- The archive is append-only only as far as the Collector is concerned: root on the host can edit or delete it. Real tamper resistance needs the archive shipped off the host as it is written (e.g. to append-only object storage); that is future work.
- Redaction is a safety net with known gaps (span names, status messages, event names, link attributes, unrecognised formats).
- Langfuse becomes one more exporter in the same pipelines, after identity stamping and redaction.
- The CA keeps its name `openbao-ca-*` and now signs the certificates of two host services.
