package main

import (
	"fmt"
	"slices"

	"github.com/a2aproject/a2a-go/v2/a2a"
)

// Metadata keys of a SendMessage request that state its provenance.
const (
	// The principal the caller acts for; only one of the caller's
	// configured principals. Without it, the caller acts for itself.
	metaPrincipal = "backfabric.io/principal"
	// The channel the message came through (e.g. a chat adapter's name),
	// recorded as the caller states it.
	metaChannel = "backfabric.io/channel"
)

// Provenance of a message: who sent it, for whom, and through what.
type Provenance struct {
	Caller    Identity
	Principal string
	Channel   string
}

// Caller returns the agent's entry for an authenticated identity, if the
// identity may call the agent at all. Deny by default.
func (a *Agent) Caller(id Identity) (*Caller, bool) {
	for i := range a.Callers {
		c := &a.Callers[i]
		if c.Issuer == id.Issuer && c.Subject == id.Subject {
			return c, true
		}
	}
	return nil, false
}

// Provenance decides on whose behalf an allowed caller sends a message,
// from the request's metadata.
func (c *Caller) Provenance(id Identity, meta map[string]any) (Provenance, error) {
	p := Provenance{Caller: id, Principal: id.Subject}
	principal, err := metaString(meta, metaPrincipal)
	if err != nil {
		return Provenance{}, err
	}
	if principal != "" && principal != id.Subject {
		if !slices.Contains(c.Principals, principal) {
			return Provenance{}, fmt.Errorf("%w: %s may not act for %q", a2a.ErrUnauthorized, id, principal)
		}
		p.Principal = principal
	}
	if p.Channel, err = metaString(meta, metaChannel); err != nil {
		return Provenance{}, err
	}
	return p, nil
}

func metaString(meta map[string]any, key string) (string, error) {
	v, ok := meta[key]
	if !ok {
		return "", nil
	}
	s, ok := v.(string)
	if !ok {
		return "", fmt.Errorf("%w: metadata %s must be a string", a2a.ErrInvalidParams, key)
	}
	return s, nil
}
