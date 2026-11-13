package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

var (
	storeOnce sync.Once
	store     *Store
	storeErr  error
)

// testStore is the record in a real PostgreSQL, from the libpq environment.
// The Nix build on Linux starts one (postgresqlTestHook) and sets
// DISPATCHER_TEST_DATABASE=required; elsewhere, without PGHOST, the tests
// that need it are skipped.
func testStore(t *testing.T) *Store {
	t.Helper()
	if os.Getenv("PGHOST") == "" {
		if os.Getenv("DISPATCHER_TEST_DATABASE") == "required" {
			t.Fatal("no PostgreSQL: PGHOST is not set")
		}
		t.Skip("no PostgreSQL: PGHOST is not set (nix build runs one on Linux)")
	}
	storeOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		store, storeErr = OpenStore(ctx)
	})
	if storeErr != nil {
		t.Fatal(storeErr)
	}
	return store
}

// testIssuer is a JWT issuer serving its keys over HTTP.
type testIssuer struct {
	url string
	key *rsa.PrivateKey
}

func newTestIssuer(t *testing.T) *testIssuer {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	keys := jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &key.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"}}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(keys)
	}))
	t.Cleanup(srv.Close)
	return &testIssuer{url: srv.URL, key: key}
}

func (i *testIssuer) config(audience string) Issuer {
	return Issuer{Issuer: i.url, Audience: audience, JWKSURL: i.url + "/jwks"}
}

// token signs claims, by default a valid token for subject and audience
// "dispatcher"; change adjusts them.
func (i *testIssuer) token(t *testing.T, subject string, change func(*jwt.Claims)) string {
	t.Helper()
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: jose.JSONWebKey{Key: i.key, KeyID: "k1"}},
		(&jose.SignerOptions{}).WithType("JWT"))
	if err != nil {
		t.Fatal(err)
	}
	claims := jwt.Claims{
		Issuer:   i.url,
		Subject:  subject,
		Audience: jwt.Audience{"dispatcher"},
		IssuedAt: jwt.NewNumericDate(time.Now()),
		Expiry:   jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}
	if change != nil {
		change(&claims)
	}
	raw, err := jwt.Signed(signer).Claims(claims).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
