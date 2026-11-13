package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/go-jose/go-jose/v4/jwt"
)

func TestAuthenticatorVerify(t *testing.T) {
	ctx := context.Background()
	trusted, other := newTestIssuer(t), newTestIssuer(t)
	auth, err := NewAuthenticator(ctx, map[string]Issuer{"kubernetes": trusted.config("dispatcher")})
	if err != nil {
		t.Fatal(err)
	}

	id, err := auth.Verify(ctx, trusted.token(t, "system:serviceaccount:operator:operator", nil))
	if err != nil {
		t.Fatal(err)
	}
	if want := (Identity{Issuer: "kubernetes", Subject: "system:serviceaccount:operator:operator"}); id != want {
		t.Errorf("identity %v, want %v", id, want)
	}

	// Another issuer's key under the trusted issuer's name.
	forged := other.token(t, "x", func(c *jwt.Claims) { c.Issuer = trusted.url })
	refused := map[string]string{
		"no token":            "",
		"not a JWT":           "Bearer",
		"untrusted issuer":    other.token(t, "x", nil),
		"forged signature":    forged,
		"other audience":      trusted.token(t, "x", func(c *jwt.Claims) { c.Audience = jwt.Audience{"otel-collector"} }),
		"expired":             trusted.token(t, "x", func(c *jwt.Claims) { c.Expiry = jwt.NewNumericDate(time.Now().Add(-time.Minute)) }),
		"no subject":          trusted.token(t, "", nil),
		"issuer, not exactly": trusted.token(t, "x", func(c *jwt.Claims) { c.Issuer = trusted.url + "/" }),
	}
	for name, raw := range refused {
		if id, err := auth.Verify(ctx, raw); err == nil {
			t.Errorf("%s: accepted as %v", name, id)
		}
	}
}

func TestProvenance(t *testing.T) {
	id := Identity{Issuer: "kubernetes", Subject: "system:serviceaccount:chat:adapter"}
	agent := Agent{Callers: []Caller{{Issuer: "kubernetes", Subject: id.Subject, Principals: []string{"alice"}}}}

	if _, ok := agent.Caller(Identity{Issuer: "other", Subject: id.Subject}); ok {
		t.Error("a caller of another issuer with the same subject is admitted")
	}
	caller, ok := agent.Caller(id)
	if !ok {
		t.Fatal("configured caller not admitted")
	}

	tests := []struct {
		name      string
		meta      map[string]any
		principal string
		err       error
	}{
		{"for itself", nil, id.Subject, nil},
		{"for itself, named", map[string]any{metaPrincipal: id.Subject}, id.Subject, nil},
		{"for a configured principal", map[string]any{metaPrincipal: "alice", metaChannel: "chat"}, "alice", nil},
		{"for anyone else", map[string]any{metaPrincipal: "bob"}, "", a2a.ErrUnauthorized},
		{"not a string", map[string]any{metaPrincipal: 1}, "", a2a.ErrInvalidParams},
	}
	for _, tt := range tests {
		p, err := caller.Provenance(id, tt.meta)
		if !errors.Is(err, tt.err) || err == nil && p.Principal != tt.principal {
			t.Errorf("%s: principal %q, error %v; want %q, %v", tt.name, p.Principal, err, tt.principal, tt.err)
		}
	}
}
