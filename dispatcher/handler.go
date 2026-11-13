package main

import (
	"context"
	"fmt"
	"iter"
	"log/slog"
	"net/http"
	"strings"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
)

// NewServer serves every configured agent under /agents/<name>/: its
// agent card at .well-known/agent-card.json and A2A 1.0 over JSON-RPC.
func NewServer(cfg *Config, auth *Authenticator, store *Store, audit *Auditor) (http.Handler, error) {
	mux := http.NewServeMux()
	for name, agent := range cfg.Agents {
		card := agentCard(cfg, name, agent)
		enforcer, err := a2asrv.NewAgentCardEnforcer(card)
		if err != nil {
			return nil, fmt.Errorf("agent %s: %w", name, err)
		}
		handler := &a2asrv.InterceptedHandler{
			Handler: &agentHandler{name: name, store: store, audit: audit},
			Interceptors: []a2asrv.CallInterceptor{
				&gate{agentName: name, agent: agent, auth: auth, audit: audit},
				enforcer,
			},
		}
		prefix := "/agents/" + name
		mux.Handle("GET "+prefix+a2asrv.WellKnownAgentCardPath, a2asrv.NewStaticAgentCardHandler(card))
		mux.Handle("POST "+prefix+"/", a2asrv.NewJSONRPCHandler(handler))
	}
	// Liveness and readiness: the record answers.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := store.Ping(r.Context()); err != nil {
			http.Error(w, "database: "+err.Error(), http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "ok")
	})
	return mux, nil
}

const securityScheme a2a.SecuritySchemeName = "bearer"

func agentCard(cfg *Config, name string, agent Agent) *a2a.AgentCard {
	skills := agent.Skills
	if skills == nil {
		skills = []a2a.AgentSkill{}
	}
	return &a2a.AgentCard{
		Name:        name,
		Description: agent.Description,
		Version:     agent.Version,
		SupportedInterfaces: []*a2a.AgentInterface{
			a2a.NewAgentInterface(strings.TrimSuffix(cfg.URL, "/")+"/agents/"+name+"/", a2a.TransportProtocolJSONRPC),
		},
		// The agents take text (the agent image's supervisor) and turns
		// run in the background: no streaming, no push notifications yet.
		Capabilities:       a2a.AgentCapabilities{},
		DefaultInputModes:  []string{"text/plain"},
		DefaultOutputModes: []string{"text/plain"},
		Skills:             skills,
		SecuritySchemes: a2a.NamedSecuritySchemes{
			securityScheme: a2a.HTTPAuthSecurityScheme{
				Scheme:       "Bearer",
				BearerFormat: "JWT",
				Description:  "A JWT of a trusted issuer with audience of that issuer's configuration (a Kubernetes service account token: audience dispatcher).",
			},
		},
		SecurityRequirements: a2a.SecurityRequirementsOptions{{securityScheme: {}}},
	}
}

type callerKey struct{}

type authorizedCaller struct {
	id     Identity
	caller *Caller
}

// gate authenticates every call and admits only the agent's callers.
type gate struct {
	agentName string
	agent     Agent
	auth      *Authenticator
	audit     *Auditor
}

func (g *gate) Before(ctx context.Context, callCtx *a2asrv.CallContext, req *a2asrv.Request) (context.Context, any, error) {
	refuse := func(id *Identity, err error) (context.Context, any, error) {
		g.audit.Emit(ctx, AuditEvent{Name: eventRefused, Agent: g.agentName, Method: callCtx.Method(), Caller: id, Reason: err.Error()})
		return ctx, nil, err
	}
	header, _ := callCtx.ServiceParams().Get("Authorization")
	id, err := g.auth.Verify(ctx, bearerToken(header))
	if err != nil {
		return refuse(nil, fmt.Errorf("%w: %v", a2a.ErrUnauthenticated, err))
	}
	caller, ok := g.agent.Caller(id)
	if !ok {
		return refuse(&id, fmt.Errorf("%w: %s may not call agent %s", a2a.ErrUnauthorized, id, g.agentName))
	}
	callCtx.User = a2asrv.NewAuthenticatedUser(id.String(), nil)
	return context.WithValue(ctx, callerKey{}, authorizedCaller{id: id, caller: caller}), nil, nil
}

// After keeps the dispatcher's own failures (the database's errors) from
// the caller: they are logged, and the caller gets an internal error.
func (g *gate) After(ctx context.Context, callCtx *a2asrv.CallContext, resp *a2asrv.Response) error {
	if resp.Err != nil && !isA2AError(resp.Err) {
		slog.ErrorContext(ctx, "call failed", "agent", g.agentName, "method", callCtx.Method(), "error", resp.Err)
		resp.Err = a2a.ErrInternalError
	}
	return nil
}

func callerFrom(ctx context.Context) authorizedCaller {
	c, ok := ctx.Value(callerKey{}).(authorizedCaller)
	if !ok {
		// Every call passes the gate first.
		panic("call without an authorized caller")
	}
	return c
}

// agentHandler serves one agent's A2A methods from the record.
type agentHandler struct {
	name  string
	store *Store
	audit *Auditor
}

var _ a2asrv.RequestHandler = (*agentHandler)(nil)

// SendMessage records the message and its task and answers with the task,
// in state submitted, once both are committed.
func (h *agentHandler) SendMessage(ctx context.Context, req *a2a.SendMessageRequest) (a2a.SendMessageResult, error) {
	c := callerFrom(ctx)
	msg := req.Message
	if msg == nil || msg.ID == "" || len(msg.Parts) == 0 {
		return nil, fmt.Errorf("%w: a message with messageId and parts is required", a2a.ErrInvalidParams)
	}
	if msg.Role != a2a.MessageRoleUser {
		return nil, fmt.Errorf("%w: the message's role must be ROLE_USER", a2a.ErrInvalidParams)
	}
	if req.Config != nil && req.Config.PushConfig != nil {
		return nil, a2a.ErrPushNotificationNotSupported
	}
	prov, err := c.caller.Provenance(c.id, req.Metadata)
	if err != nil {
		h.audit.Emit(ctx, AuditEvent{Name: eventRefused, Agent: h.name, Method: "SendMessage", Caller: &c.id, MessageID: msg.ID, Reason: err.Error()})
		return nil, err
	}
	task, duplicate, err := h.store.Submit(ctx, h.name, msg, prov)
	if err != nil {
		if isA2AError(err) {
			h.audit.Emit(ctx, AuditEvent{Name: eventRefused, Agent: h.name, Method: "SendMessage", Caller: &c.id, MessageID: msg.ID, Principal: prov.Principal, Channel: prov.Channel, Reason: err.Error()})
		}
		return nil, err
	}
	h.audit.Emit(ctx, AuditEvent{
		Name: eventAccepted, Agent: h.name, TaskID: string(task.ID), ContextID: task.ContextID, MessageID: msg.ID,
		Caller: &c.id, Principal: prov.Principal, Channel: prov.Channel, Duplicate: duplicate,
	})
	if req.Config != nil && req.Config.HistoryLength != nil {
		task.History = lastMessages(task.History, *req.Config.HistoryLength)
	}
	return task, nil
}

func (h *agentHandler) GetTask(ctx context.Context, req *a2a.GetTaskRequest) (*a2a.Task, error) {
	return h.store.Task(ctx, h.name, callerFrom(ctx).id, req.ID, req.HistoryLength)
}

// CancelTask cancels a task that has not finished.
func (h *agentHandler) CancelTask(ctx context.Context, req *a2a.CancelTaskRequest) (*a2a.Task, error) {
	c := callerFrom(ctx)
	task, err := h.store.Cancel(ctx, h.name, c.id, req.ID)
	if err != nil {
		return nil, err
	}
	h.audit.Emit(ctx, AuditEvent{Name: eventCancelled, Agent: h.name, TaskID: string(task.ID), ContextID: task.ContextID, Caller: &c.id})
	return task, nil
}

func (h *agentHandler) ListTasks(context.Context, *a2a.ListTasksRequest) (*a2a.ListTasksResponse, error) {
	return nil, a2a.ErrUnsupportedOperation
}

func (h *agentHandler) SendStreamingMessage(context.Context, *a2a.SendMessageRequest) iter.Seq2[a2a.Event, error] {
	return errorSeq(a2a.ErrUnsupportedOperation)
}

func (h *agentHandler) SubscribeToTask(context.Context, *a2a.SubscribeToTaskRequest) iter.Seq2[a2a.Event, error] {
	return errorSeq(a2a.ErrUnsupportedOperation)
}

func (h *agentHandler) GetTaskPushConfig(context.Context, *a2a.GetTaskPushConfigRequest) (*a2a.PushConfig, error) {
	return nil, a2a.ErrPushNotificationNotSupported
}

func (h *agentHandler) ListTaskPushConfigs(context.Context, *a2a.ListTaskPushConfigRequest) (*a2a.ListTaskPushConfigResponse, error) {
	return nil, a2a.ErrPushNotificationNotSupported
}

func (h *agentHandler) CreateTaskPushConfig(context.Context, *a2a.PushConfig) (*a2a.PushConfig, error) {
	return nil, a2a.ErrPushNotificationNotSupported
}

func (h *agentHandler) DeleteTaskPushConfig(context.Context, *a2a.DeleteTaskPushConfigRequest) error {
	return a2a.ErrPushNotificationNotSupported
}

func (h *agentHandler) GetExtendedAgentCard(context.Context, *a2a.GetExtendedAgentCardRequest) (*a2a.AgentCard, error) {
	return nil, a2a.ErrExtendedCardNotConfigured
}

func errorSeq(err error) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) { yield(nil, err) }
}

func lastMessages(history []*a2a.Message, n int) []*a2a.Message {
	return history[len(history)-min(max(n, 0), len(history)):]
}

// isA2AError tells a refusal (an A2A error for the caller) from a failure
// of the dispatcher.
func isA2AError(err error) bool {
	return a2a.ErrorReason(err) != a2a.ErrorReason(a2a.ErrInternalError)
}
