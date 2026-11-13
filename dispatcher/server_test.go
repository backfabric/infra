package main

import (
	"context"
	"errors"
	"net/http/httptest"
	"testing"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2aclient"
	"github.com/a2aproject/a2a-go/v2/a2aclient/agentcard"
)

// TestServer drives the dispatcher with a2a-go's own client, as callers
// will: agent card, bearer token, SendMessage, GetTask, CancelTask.
func TestServer(t *testing.T) {
	s, ctx := testStore(t), context.Background()
	iss := newTestIssuer(t)
	operator := "system:serviceaccount:operator:operator"
	cfg := &Config{
		Listen:  ":0",
		Issuers: map[string]Issuer{"kubernetes": iss.config("dispatcher")},
		Agents: map[string]Agent{"codex": {
			Description: "Codex",
			Version:     "1",
			Callers:     []Caller{{Issuer: "kubernetes", Subject: operator}},
		}},
	}
	auth, err := NewAuthenticator(ctx, cfg.Issuers)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(nil)
	cfg.URL = "http://" + srv.Listener.Addr().String()
	handler, err := NewServer(cfg, auth, s, &Auditor{})
	if err != nil {
		t.Fatal(err)
	}
	srv.Config.Handler = handler
	srv.Start()
	t.Cleanup(srv.Close)

	card, err := agentcard.NewResolver(nil).Resolve(ctx, srv.URL+"/agents/codex/.well-known/agent-card.json")
	if err != nil {
		t.Fatal(err)
	}
	creds := a2aclient.NewInMemoryCredentialsStore()
	client, err := a2aclient.NewFromCard(ctx, card, a2aclient.WithCallInterceptors(&a2aclient.AuthInterceptor{Service: creds}))
	if err != nil {
		t.Fatal(err)
	}
	session := func(name, token string) context.Context {
		creds.Set(a2aclient.SessionID(name), securityScheme, a2aclient.AuthCredential(token))
		return a2aclient.AttachSessionID(ctx, a2aclient.SessionID(name))
	}
	send := func(ctx context.Context, id string) (a2a.SendMessageResult, error) {
		return client.SendMessage(ctx, &a2a.SendMessageRequest{Message: userMessage(id, "", "")})
	}

	if _, err := send(ctx, "anonymous"); !errors.Is(err, a2a.ErrUnauthenticated) {
		t.Errorf("without a token: %v, want unauthenticated", err)
	}
	if _, err := send(session("stranger", iss.token(t, "system:serviceaccount:x:y", nil)), "s1"); !errors.Is(err, a2a.ErrUnauthorized) {
		t.Errorf("a caller not configured: %v, want unauthorized", err)
	}

	op := session("operator", iss.token(t, operator, nil))
	result, err := send(op, a2a.NewMessageID())
	if err != nil {
		t.Fatal(err)
	}
	task, ok := result.(*a2a.Task)
	if !ok || task.Status.State != a2a.TaskStateSubmitted {
		t.Fatalf("SendMessage: %#v, want a submitted task", result)
	}
	if got, err := client.GetTask(op, &a2a.GetTaskRequest{ID: task.ID}); err != nil || got.ID != task.ID {
		t.Errorf("GetTask: %v, %v", got, err)
	}
	if got, err := client.CancelTask(op, &a2a.CancelTaskRequest{ID: task.ID}); err != nil || got.Status.State != a2a.TaskStateCanceled {
		t.Errorf("CancelTask: %v, %v", got, err)
	}
}
