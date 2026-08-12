package auth

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"reliquary-be/config"
)

const testKeyID = "test-key"

// testIdP is a minimal OIDC provider: discovery, a JWKS, and a userinfo
// endpoint that accepts any token it has been told about. Accepting tokens at
// userinfo regardless of who they were issued for is exactly what a real
// provider does, which is why the audience check cannot be delegated to it.
type testIdP struct {
	server *httptest.Server
	key    *rsa.PrivateKey
	// userinfo maps an access token to the username it resolves to.
	userinfo map[string]string
}

func newTestIdP(t *testing.T) *testIdP {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	idp := &testIdP{key: key, userinfo: map[string]string{}}
	mux := http.NewServeMux()
	idp.server = httptest.NewServer(mux)
	t.Cleanup(idp.server.Close)

	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"issuer":                 idp.server.URL,
			"authorization_endpoint": idp.server.URL + "/authorize",
			"token_endpoint":         idp.server.URL + "/token",
			"jwks_uri":               idp.server.URL + "/jwks.json",
			"userinfo_endpoint":      idp.server.URL + "/userinfo",
		})
	})

	mux.HandleFunc("/jwks.json", func(w http.ResponseWriter, r *http.Request) {
		pub := key.Public().(*rsa.PublicKey)
		json.NewEncoder(w).Encode(map[string]any{
			"keys": []map[string]string{{
				"kty": "RSA",
				"use": "sig",
				"alg": "RS256",
				"kid": testKeyID,
				"n":   base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
				"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes()),
			}},
		})
	})

	mux.HandleFunc("/userinfo", func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		username, ok := idp.userinfo[token]
		if !ok {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"preferred_username": username})
	})

	return idp
}

// sign issues an RS256 token with the given claims, filling in iss and exp
// unless the caller set them.
func (i *testIdP) sign(t *testing.T, claims jwt.MapClaims) string {
	t.Helper()

	if _, ok := claims["iss"]; !ok {
		claims["iss"] = i.server.URL
	}
	if _, ok := claims["exp"]; !ok {
		claims["exp"] = time.Now().Add(time.Hour).Unix()
	}

	token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	token.Header["kid"] = testKeyID
	signed, err := token.SignedString(i.key)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return signed
}

func (i *testIdP) config(audience string, allowOpaque bool) *config.Config {
	return &config.Config{
		OIDCIssuerURL:         i.server.URL,
		OIDCAudience:          audience,
		OIDCUsernameClaim:     "preferred_username",
		OIDCAllowOpaqueTokens: allowOpaque,
	}
}

func (i *testIdP) authenticator(t *testing.T, audience string, allowOpaque bool) *OIDCAuthenticator {
	t.Helper()

	o, err := NewOIDCAuthenticator(t.Context(), i.config(audience, allowOpaque))
	if err != nil {
		t.Fatalf("NewOIDCAuthenticator: %v", err)
	}
	return o
}

func bearerRequest(t *testing.T, token string) *http.Request {
	t.Helper()

	req := httptest.NewRequest(http.MethodGet, "/api/files", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	return req.WithContext(t.Context())
}

// Without an expected audience there is nothing to check a token against, so
// the backend must refuse to start rather than accept every token the issuer
// ever minted.
func TestNewOIDCAuthenticatorRequiresAudience(t *testing.T) {
	idp := newTestIdP(t)

	if _, err := NewOIDCAuthenticator(t.Context(), idp.config("", false)); err == nil {
		t.Fatal("expected an error with no audience configured")
	}

	// Opaque tokens cannot be audience-checked at all, so that mode is the one
	// explicit way to run without one.
	if _, err := NewOIDCAuthenticator(t.Context(), idp.config("", true)); err != nil {
		t.Fatalf("opaque mode should not require an audience: %v", err)
	}
}

func TestOIDCAcceptsTokenForConfiguredAudience(t *testing.T) {
	idp := newTestIdP(t)
	o := idp.authenticator(t, "reliquary", false)

	token := idp.sign(t, jwt.MapClaims{
		"aud":                "reliquary",
		"sub":                "user-1",
		"preferred_username": "alice",
	})

	username, err := o.AuthenticateRequest(bearerRequest(t, token))
	if err != nil {
		t.Fatalf("AuthenticateRequest: %v", err)
	}
	if username != "alice" {
		t.Errorf("username = %q, want %q", username, "alice")
	}
}

// The core of the fix: a token the same provider issued for a different
// application must not authenticate here, even though userinfo accepts it.
func TestOIDCRejectsTokenForAnotherAudience(t *testing.T) {
	idp := newTestIdP(t)
	o := idp.authenticator(t, "reliquary", false)

	token := idp.sign(t, jwt.MapClaims{
		"aud":                "some-other-app",
		"sub":                "user-1",
		"preferred_username": "alice",
	})
	// The provider itself considers this token perfectly valid.
	idp.userinfo[token] = "alice"

	if _, err := o.AuthenticateRequest(bearerRequest(t, token)); err == nil {
		t.Fatal("token issued for another audience was accepted")
	}
}

// A token listing several audiences is fine as long as we are one of them.
func TestOIDCAcceptsTokenWithMultipleAudiences(t *testing.T) {
	idp := newTestIdP(t)
	o := idp.authenticator(t, "reliquary", false)

	token := idp.sign(t, jwt.MapClaims{
		"aud":                []string{"some-other-app", "reliquary"},
		"preferred_username": "alice",
	})

	if _, err := o.AuthenticateRequest(bearerRequest(t, token)); err != nil {
		t.Fatalf("AuthenticateRequest: %v", err)
	}
}

func TestOIDCRejectsInvalidTokens(t *testing.T) {
	idp := newTestIdP(t)
	other := newTestIdP(t)

	tests := []struct {
		name  string
		token func() string
	}{
		{"expired", func() string {
			return idp.sign(t, jwt.MapClaims{
				"aud":                "reliquary",
				"exp":                time.Now().Add(-time.Minute).Unix(),
				"preferred_username": "alice",
			})
		}},
		{"another issuer", func() string {
			return idp.sign(t, jwt.MapClaims{
				"aud":                "reliquary",
				"iss":                "https://evil.example.com",
				"preferred_username": "alice",
			})
		}},
		{"signed by another key", func() string {
			// Correct issuer and audience, wrong signing key.
			return other.sign(t, jwt.MapClaims{
				"aud":                "reliquary",
				"iss":                idp.server.URL,
				"preferred_username": "alice",
			})
		}},
		{"no audience", func() string {
			return idp.sign(t, jwt.MapClaims{"preferred_username": "alice"})
		}},
		{"unsigned", func() string {
			header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`))
			payload := base64.RawURLEncoding.EncodeToString([]byte(
				`{"aud":"reliquary","preferred_username":"alice"}`))
			return header + "." + payload + "."
		}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			o := idp.authenticator(t, "reliquary", false)
			token := tt.token()
			idp.userinfo[token] = "alice"
			other.userinfo[token] = "alice"

			if _, err := o.AuthenticateRequest(bearerRequest(t, token)); err == nil {
				t.Error("invalid token was accepted")
			}
		})
	}
}

func TestOIDCOpaqueTokens(t *testing.T) {
	idp := newTestIdP(t)
	const token = "opaque-random-string"
	idp.userinfo[token] = "alice"

	// Rejected by default: nothing about an opaque token can be checked locally.
	strict := idp.authenticator(t, "reliquary", false)
	if _, err := strict.AuthenticateRequest(bearerRequest(t, token)); err == nil {
		t.Error("opaque token accepted without OIDC_ALLOW_OPAQUE_TOKENS")
	}

	// Accepted behind the explicit opt-in, resolved via userinfo.
	lax := idp.authenticator(t, "reliquary", true)
	username, err := lax.AuthenticateRequest(bearerRequest(t, token))
	if err != nil {
		t.Fatalf("AuthenticateRequest: %v", err)
	}
	if username != "alice" {
		t.Errorf("username = %q, want %q", username, "alice")
	}
}

// Some providers keep profile claims out of the access token. The token is
// still verified first; userinfo only supplies the name.
func TestOIDCFallsBackToUserinfoForMissingUsernameClaim(t *testing.T) {
	idp := newTestIdP(t)
	o := idp.authenticator(t, "reliquary", false)

	token := idp.sign(t, jwt.MapClaims{"aud": "reliquary", "sub": "user-1"})
	idp.userinfo[token] = "alice"

	username, err := o.AuthenticateRequest(bearerRequest(t, token))
	if err != nil {
		t.Fatalf("AuthenticateRequest: %v", err)
	}
	if username != "alice" {
		t.Errorf("username = %q, want %q", username, "alice")
	}
}

// The provider is trusted to say who the user is, not to hand over a value
// that is safe to splice into an object key.
func TestOIDCRejectsUnsafeUsernameClaim(t *testing.T) {
	unsafe := []string{"../admin", "alice/../bob", "alice/", "alice bob"}

	for _, username := range unsafe {
		t.Run(username, func(t *testing.T) {
			idp := newTestIdP(t)
			o := idp.authenticator(t, "reliquary", false)

			// Once via the access token's own claim...
			token := idp.sign(t, jwt.MapClaims{
				"aud":                "reliquary",
				"preferred_username": username,
			})
			if _, err := o.AuthenticateRequest(bearerRequest(t, token)); err == nil {
				t.Error("unsafe username in token claim was accepted")
			}

			// ...and once via the userinfo fallback.
			claimless := idp.sign(t, jwt.MapClaims{"aud": "reliquary", "sub": "user-1"})
			idp.userinfo[claimless] = username
			if _, err := o.AuthenticateRequest(bearerRequest(t, claimless)); err == nil {
				t.Error("unsafe username from userinfo was accepted")
			}
		})
	}
}

func TestLooksLikeJWT(t *testing.T) {
	idp := newTestIdP(t)
	signed := idp.sign(t, jwt.MapClaims{"aud": "reliquary"})

	tests := []struct {
		token string
		want  bool
	}{
		{signed, true},
		{"opaque-random-string", false},
		{"", false},
		{"a.b", false},
		{"a.b.c", false},                 // header is not valid base64url JSON
		{"e30.e30.sig", false},           // decodes to {} — no alg
		{signed + ".extra", false},       // four segments
		{"!!!." + "e30" + ".sig", false}, // undecodable header
	}

	for _, tt := range tests {
		if got := looksLikeJWT(tt.token); got != tt.want {
			t.Errorf("looksLikeJWT(%.20q) = %v, want %v", tt.token, got, tt.want)
		}
	}
}

// A cached identity must never outlive the token that produced it.
func TestCacheExpiryCappedByTokenExpiry(t *testing.T) {
	shortLived := time.Now().Add(30 * time.Second)
	if got := cacheExpiry(shortLived); !got.Equal(shortLived) {
		t.Errorf("cacheExpiry(%v) = %v, want the token expiry", shortLived, got)
	}

	// A long-lived token still gets the normal TTL, so revocation at the
	// provider takes effect within it.
	longLived := time.Now().Add(24 * time.Hour)
	if got := cacheExpiry(longLived); !got.Before(time.Now().Add(userinfoCacheTTL + time.Second)) {
		t.Errorf("cacheExpiry(%v) = %v, want at most the userinfo TTL", longLived, got)
	}

	// Opaque tokens report no expiry; the TTL applies.
	if got := cacheExpiry(time.Time{}); got.Before(time.Now()) {
		t.Errorf("cacheExpiry(zero) = %v, want a future deadline", got)
	}
}
