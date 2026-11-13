package main

import (
	"context"
	"crypto/tls"
	"log/slog"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	otellog "go.opentelemetry.io/otel/log"
	sdklog "go.opentelemetry.io/otel/sdk/log"
)

// Audit event names: one per decision and transition (ADR 0028).
const (
	eventAccepted  = "dispatcher.accepted"
	eventRefused   = "dispatcher.refused"
	eventCancelled = "dispatcher.cancelled"
)

// AuditEvent is one audit event. Message contents never go into it; they
// stay in the record.
type AuditEvent struct {
	Name      string
	Agent     string
	TaskID    string
	ContextID string
	MessageID string
	// Caller is unset for a request that did not authenticate.
	Caller    *Identity
	Principal string
	Channel   string
	// Method is the A2A method of the request.
	Method string
	// Duplicate marks an accepted message that was already in the record.
	Duplicate bool
	// Reason of a refusal.
	Reason string
}

func (e AuditEvent) attributes() []attribute.KeyValue {
	attrs := []attribute.KeyValue{attribute.String("dispatcher.agent", e.Agent)}
	add := func(key, value string) {
		if value != "" {
			attrs = append(attrs, attribute.String(key, value))
		}
	}
	add("dispatcher.method", e.Method)
	add("a2a.task_id", e.TaskID)
	add("a2a.context_id", e.ContextID)
	add("a2a.message_id", e.MessageID)
	if e.Caller != nil {
		add("dispatcher.caller.issuer", e.Caller.Issuer)
		add("dispatcher.caller.subject", e.Caller.Subject)
	}
	add("dispatcher.principal", e.Principal)
	add("dispatcher.channel", e.Channel)
	add("dispatcher.reason", e.Reason)
	if e.Duplicate {
		attrs = append(attrs, attribute.Bool("dispatcher.duplicate", true))
	}
	return attrs
}

// Auditor writes audit events to the log and, if an OTLP endpoint is
// configured, to the OpenTelemetry Collector (ADR 0021) as log events.
type Auditor struct {
	provider *sdklog.LoggerProvider
	logger   otellog.Logger
}

// NewAuditor exports over OTLP/HTTP when OTEL_EXPORTER_OTLP_ENDPOINT (or
// OTEL_EXPORTER_OTLP_LOGS_ENDPOINT) is set, trusting the CA in
// OTEL_EXPORTER_OTLP_CERTIFICATE and sending the token in cfg.TokenFile.
func NewAuditor(ctx context.Context, cfg Audit) (*Auditor, error) {
	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" && os.Getenv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT") == "" {
		slog.Info("audit events go to the log only: no OTLP endpoint")
		return &Auditor{}, nil
	}
	// An own client, for the token; the exporter then ignores the
	// certificate variable, so it is read here.
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if caFile := os.Getenv("OTEL_EXPORTER_OTLP_CERTIFICATE"); caFile != "" {
		pool, err := loadCAs(caFile)
		if err != nil {
			return nil, err
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	var rt http.RoundTripper = transport
	if cfg.TokenFile != "" {
		rt = &bearerTransport{base: transport, tokenFile: cfg.TokenFile}
	}
	exporter, err := otlploghttp.New(ctx, otlploghttp.WithHTTPClient(&http.Client{Transport: rt, Timeout: 10 * time.Second}))
	if err != nil {
		return nil, err
	}
	provider := sdklog.NewLoggerProvider(sdklog.WithProcessor(sdklog.NewBatchProcessor(exporter)))
	return &Auditor{provider: provider, logger: provider.Logger("dispatcher")}, nil
}

// Emit records one event.
func (a *Auditor) Emit(ctx context.Context, e AuditEvent) {
	attrs := e.attributes()
	logAttrs := make([]any, 0, len(attrs)+1)
	logAttrs = append(logAttrs, slog.String("event", e.Name))
	for _, kv := range attrs {
		logAttrs = append(logAttrs, slog.Any(string(kv.Key), kv.Value.AsInterface()))
	}
	slog.InfoContext(ctx, "audit", logAttrs...)
	if a.logger == nil {
		return
	}
	var r otellog.Record
	r.SetEventName(e.Name)
	r.SetTimestamp(time.Now())
	r.SetSeverity(otellog.SeverityInfo)
	r.AddAttributes(attrs...)
	// Exported after the request; its cancellation must not drop the event.
	a.logger.Emit(context.WithoutCancel(ctx), r)
}

// Shutdown flushes the queued events.
func (a *Auditor) Shutdown(ctx context.Context) error {
	if a.provider == nil {
		return nil
	}
	return a.provider.Shutdown(ctx)
}
