package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

// Identity is an authenticated caller: the name of the issuer (in
// Config.Issuers) that vouched for it and the token's subject.
type Identity struct {
	Issuer  string
	Subject string
}

func (id Identity) String() string { return id.Issuer + "/" + id.Subject }

// Authenticator verifies JWTs against the trusted issuers: signature,
// issuer, audience and expiry, in the process (go-oidc).
type Authenticator struct {
	// By the exact `iss` claim.
	issuers map[string]issuerVerifier
}

type issuerVerifier struct {
	name     string
	verifier *oidc.IDTokenVerifier
}

// NewAuthenticator prepares a verifier per issuer. Keys are fetched on first
// use and again when a token names an unknown key id, so a rotated key needs
// no restart.
func NewAuthenticator(ctx context.Context, issuers map[string]Issuer) (*Authenticator, error) {
	a := &Authenticator{issuers: map[string]issuerVerifier{}}
	for name, iss := range issuers {
		client, err := issuerClient(iss)
		if err != nil {
			return nil, fmt.Errorf("issuer %s: %w", name, err)
		}
		// The keys are fetched with the client of this context, also later.
		ictx := oidc.ClientContext(context.WithoutCancel(ctx), client)
		cfg := &oidc.Config{ClientID: iss.Audience}
		var verifier *oidc.IDTokenVerifier
		if iss.JWKSURL != "" {
			verifier = oidc.NewVerifier(iss.Issuer, oidc.NewRemoteKeySet(ictx, iss.JWKSURL), cfg)
		} else {
			provider, err := oidc.NewProvider(ictx, iss.Issuer)
			if err != nil {
				return nil, fmt.Errorf("issuer %s: discovery: %w", name, err)
			}
			verifier = provider.Verifier(cfg)
		}
		if _, dup := a.issuers[iss.Issuer]; dup {
			return nil, fmt.Errorf("issuer %s: %s is configured twice", name, iss.Issuer)
		}
		a.issuers[iss.Issuer] = issuerVerifier{name: name, verifier: verifier}
	}
	return a, nil
}

// Verify returns the identity of a raw JWT from a trusted issuer.
func (a *Authenticator) Verify(ctx context.Context, raw string) (Identity, error) {
	if raw == "" {
		return Identity{}, errors.New("no bearer token")
	}
	iss, err := unverifiedIssuer(raw)
	if err != nil {
		return Identity{}, err
	}
	// The unverified claim only picks the verifier, which checks it again.
	v, ok := a.issuers[iss]
	if !ok {
		return Identity{}, fmt.Errorf("untrusted issuer %q", iss)
	}
	token, err := v.verifier.Verify(ctx, raw)
	if err != nil {
		return Identity{}, err
	}
	if token.Subject == "" {
		return Identity{}, errors.New("token has no subject")
	}
	return Identity{Issuer: v.name, Subject: token.Subject}, nil
}

func unverifiedIssuer(raw string) (string, error) {
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return "", errors.New("malformed JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", fmt.Errorf("malformed JWT: %w", err)
	}
	var claims struct {
		Issuer string `json:"iss"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return "", fmt.Errorf("malformed JWT: %w", err)
	}
	return claims.Issuer, nil
}

// bearerToken returns the token of an `Authorization: Bearer` value.
func bearerToken(values []string) string {
	if len(values) != 1 {
		return ""
	}
	scheme, token, ok := strings.Cut(values[0], " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
		return ""
	}
	return strings.TrimSpace(token)
}

// issuerClient is the HTTP client that fetches an issuer's keys.
func issuerClient(iss Issuer) (*http.Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if iss.CAFile != "" {
		pool, err := loadCAs(iss.CAFile)
		if err != nil {
			return nil, err
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	var rt http.RoundTripper = transport
	if iss.TokenFile != "" {
		rt = &bearerTransport{base: transport, tokenFile: iss.TokenFile}
	}
	return &http.Client{
		Transport: rt,
		// go-oidc refreshes keys one fetch at a time: a hung fetch would
		// hold back every later one.
		Timeout: 10 * time.Second,
		// The token goes to the configured URL only, never to a redirect.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}, nil
}

func loadCAs(path string) (*x509.CertPool, error) {
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("%s: no PEM certificates", path)
	}
	return pool, nil
}

// bearerTransport sends the token in tokenFile with every request, read
// again each time: the kubelet renews projected service account tokens in
// place.
type bearerTransport struct {
	base      http.RoundTripper
	tokenFile string
}

func (t *bearerTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	token, err := os.ReadFile(t.tokenFile)
	if err != nil {
		return nil, err
	}
	req = req.Clone(req.Context())
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	return t.base.RoundTrip(req)
}
