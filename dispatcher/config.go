package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"regexp"

	"github.com/a2aproject/a2a-go/v2/a2a"
)

// Config is the dispatcher's configuration file (README.md, "Configuration").
type Config struct {
	// Listen is the address of the A2A server, e.g. ":8080".
	Listen string `json:"listen"`
	// URL is the base URL callers reach the dispatcher at; agent cards
	// advertise URL + "/agents/<name>".
	URL string `json:"url"`
	// Issuers are the trusted JWT issuers by name; a caller is identified
	// by the issuer's name and the token's subject.
	Issuers map[string]Issuer `json:"issuers"`
	// Audit configures the audit events' export (OTLP, see audit.go).
	Audit Audit `json:"audit"`
	// Agents by name: each gets an A2A endpoint and agent card.
	Agents map[string]Agent `json:"agents"`
	// MaxRequestBytes bounds a request's body (default 1 MiB): a2a-go
	// decodes it whole before the caller is authenticated.
	MaxRequestBytes int64 `json:"maxRequestBytes,omitempty"`
}

const defaultMaxRequestBytes = 1 << 20

func (c *Config) maxRequestBytes() int64 {
	if c.MaxRequestBytes == 0 {
		return defaultMaxRequestBytes
	}
	return c.MaxRequestBytes
}

// Issuer is a trusted issuer of JWTs.
type Issuer struct {
	// Issuer is the exact `iss` claim.
	Issuer string `json:"issuer"`
	// Audience is the `aud` a token must carry.
	Audience string `json:"audience"`
	// JWKSURL, if set, is where the issuer's public keys are fetched;
	// otherwise OIDC discovery at Issuer finds them.
	JWKSURL string `json:"jwksURL,omitempty"`
	// CAFile, if set, is the only CA trusted when fetching the keys.
	CAFile string `json:"caFile,omitempty"`
	// TokenFile, if set, is sent as a bearer token when fetching the keys
	// (Kubernetes' API server rejects anonymous requests).
	TokenFile string `json:"tokenFile,omitempty"`
}

// Audit configures the export of audit events. The OTLP endpoint and CA
// come from the standard OTEL_EXPORTER_OTLP_* variables; without an
// endpoint, audit events go to the log only.
type Audit struct {
	// TokenFile, if set, is sent as a bearer token with every export,
	// read again for each request (a projected service account token).
	TokenFile string `json:"tokenFile,omitempty"`
}

// Agent is an agent the dispatcher fronts.
type Agent struct {
	// Description, Version and Skills go into the agent card.
	Description string           `json:"description"`
	Version     string           `json:"version"`
	Skills      []a2a.AgentSkill `json:"skills"`
	// Callers may use the agent; everyone else is refused.
	Callers []Caller `json:"callers"`
}

// Caller is an identity allowed to call an agent.
type Caller struct {
	// Issuer is the name of an entry in Config.Issuers.
	Issuer string `json:"issuer"`
	// Subject is the token's `sub`.
	Subject string `json:"subject"`
	// Principals the caller may act on behalf of, besides itself.
	Principals []string `json:"principals,omitempty"`
}

// An agent's name is a DNS label: it is a path segment here and part of
// actor names in Substrate.
var agentName = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)

// LoadConfig reads and validates the configuration file; unknown fields are
// errors, so that a mistyped option is not silently ignored.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var cfg Config
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &cfg, nil
}

func (c *Config) validate() error {
	var errs []error
	if c.Listen == "" {
		errs = append(errs, errors.New("listen: required"))
	}
	if u, err := url.Parse(c.URL); err != nil || u.Scheme == "" || u.Host == "" {
		errs = append(errs, fmt.Errorf("url: not an absolute URL: %q", c.URL))
	}
	if c.MaxRequestBytes < 0 {
		errs = append(errs, errors.New("maxRequestBytes: must not be negative"))
	}
	if len(c.Issuers) == 0 {
		errs = append(errs, errors.New("issuers: at least one required"))
	}
	for name, iss := range c.Issuers {
		if iss.Issuer == "" || iss.Audience == "" {
			errs = append(errs, fmt.Errorf("issuers.%s: issuer and audience are required", name))
		}
	}
	for name, agent := range c.Agents {
		if !agentName.MatchString(name) {
			errs = append(errs, fmt.Errorf("agents.%s: not a DNS label", name))
		}
		if agent.Description == "" || agent.Version == "" {
			errs = append(errs, fmt.Errorf("agents.%s: description and version are required", name))
		}
		for i, caller := range agent.Callers {
			if _, ok := c.Issuers[caller.Issuer]; !ok {
				errs = append(errs, fmt.Errorf("agents.%s.callers[%d]: unknown issuer %q", name, i, caller.Issuer))
			}
			if caller.Subject == "" {
				errs = append(errs, fmt.Errorf("agents.%s.callers[%d]: subject is required", name, i))
			}
		}
	}
	return errors.Join(errs...)
}
