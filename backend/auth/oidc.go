package auth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"

	"reliquary-be/config"
)

// OIDCAuthenticator validates Bearer access tokens against the provider's
// signing keys, requiring that each token names this deployment in its aud
// claim. The provider's userinfo endpoint is used to resolve the username, but
// never as the authentication decision itself: userinfo only answers "this
// token is valid", not "valid for Reliquary", so on its own it would accept any
// token the issuer minted for any client registered with it.
type OIDCAuthenticator struct {
	verifier         *oidc.IDTokenVerifier
	userinfoEndpoint string
	usernameClaim    string
	audience         string
	allowOpaque      bool
	cache            sync.Map // token → *cachedUser
}

type cachedUser struct {
	username  string
	expiresAt time.Time
}

const userinfoCacheTTL = 5 * time.Minute

// NewOIDCAuthenticator discovers the provider's endpoints and signing keys.
func NewOIDCAuthenticator(ctx context.Context, cfg *config.Config) (*OIDCAuthenticator, error) {
	if cfg.OIDCIssuerURL == "" {
		return nil, fmt.Errorf("OIDC_ISSUER_URL is required when AUTH_MODE=oidc")
	}
	if cfg.OIDCAudience == "" && !cfg.OIDCAllowOpaqueTokens {
		return nil, fmt.Errorf("OIDC_CLIENT_ID (or OIDC_AUDIENCE) is required so access tokens " +
			"can be checked against the audience they were issued for; set " +
			"OIDC_ALLOW_OPAQUE_TOKENS=true only if the provider issues opaque access tokens")
	}

	provider, err := oidc.NewProvider(ctx, cfg.OIDCIssuerURL)
	if err != nil {
		return nil, fmt.Errorf("oidc discovery: %w", err)
	}

	// Extract userinfo endpoint from the provider's discovery document.
	var claims struct {
		UserinfoEndpoint string `json:"userinfo_endpoint"`
	}
	if err := provider.Claims(&claims); err != nil {
		return nil, fmt.Errorf("oidc discovery claims: %w", err)
	}
	if claims.UserinfoEndpoint == "" {
		return nil, fmt.Errorf("oidc provider has no userinfo_endpoint")
	}

	o := &OIDCAuthenticator{
		userinfoEndpoint: claims.UserinfoEndpoint,
		usernameClaim:    cfg.OIDCUsernameClaim,
		audience:         cfg.OIDCAudience,
		allowOpaque:      cfg.OIDCAllowOpaqueTokens,
	}
	if cfg.OIDCAudience != "" {
		o.verifier = provider.Verifier(&oidc.Config{ClientID: cfg.OIDCAudience})
	}

	slog.Info("oidc provider discovered",
		"issuer", cfg.OIDCIssuerURL,
		"userinfo_endpoint", claims.UserinfoEndpoint,
		"username_claim", cfg.OIDCUsernameClaim,
		"audience", cfg.OIDCAudience,
	)
	if cfg.OIDCAllowOpaqueTokens {
		slog.Warn("OIDC_ALLOW_OPAQUE_TOKENS is enabled; opaque access tokens cannot be " +
			"checked against an audience, so any token this provider issued for any " +
			"client will be accepted")
	}

	return o, nil
}

// Middleware validates the Bearer token and injects username/role into context.
func (o *OIDCAuthenticator) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		username, err := o.AuthenticateRequest(r)
		if err != nil {
			slog.Warn("oidc token validation failed", "error", err, "expected_audience", o.audience)
			http.Error(w, "invalid token", http.StatusUnauthorized)
			return
		}

		ctx := context.WithValue(r.Context(), ctxUsername, username)
		ctx = context.WithValue(ctx, ctxRole, RoleUser)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (o *OIDCAuthenticator) AuthenticateRequest(r *http.Request) (string, error) {
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		return "", fmt.Errorf("missing authorization header")
	}

	tokenStr := strings.TrimPrefix(authHeader, "Bearer ")
	if tokenStr == authHeader {
		return "", fmt.Errorf("invalid authorization format")
	}

	username, err := o.resolveUsername(r.Context(), tokenStr)
	if err != nil {
		return "", err
	}

	return username, nil
}

// resolveUsername returns the username for a token, using the cache if available.
func (o *OIDCAuthenticator) resolveUsername(ctx context.Context, token string) (string, error) {
	if cached, ok := o.cache.Load(token); ok {
		entry := cached.(*cachedUser)
		if time.Now().Before(entry.expiresAt) {
			return entry.username, nil
		}
		o.cache.Delete(token)
	}

	username, tokenExpiry, err := o.authenticate(ctx, token)
	if err != nil {
		return "", err
	}

	o.cache.Store(token, &cachedUser{
		username:  username,
		expiresAt: cacheExpiry(tokenExpiry),
	})

	return username, nil
}

// authenticate validates a token and returns the username along with the
// token's own expiry, which is zero when the token does not state one.
func (o *OIDCAuthenticator) authenticate(ctx context.Context, token string) (string, time.Time, error) {
	if !looksLikeJWT(token) {
		// Opaque tokens carry no claims at all, so there is nothing to check an
		// audience against locally.
		if !o.allowOpaque {
			return "", time.Time{}, fmt.Errorf("access token is not a JWT and cannot be " +
				"audience-checked; set OIDC_ALLOW_OPAQUE_TOKENS=true to accept it anyway")
		}
		username, err := o.fetchUserinfo(ctx, token)
		return username, time.Time{}, err
	}

	if o.verifier == nil {
		return "", time.Time{}, fmt.Errorf("no expected audience configured to verify this token against")
	}

	// Checks the signature against the issuer's keys, plus iss, aud and exp.
	idToken, err := o.verifier.Verify(ctx, token)
	if err != nil {
		// Deliberately no userinfo fallback: a rejected audience is precisely
		// the case this guards against, and falling back would restore the hole.
		return "", time.Time{}, fmt.Errorf("verify access token: %w", err)
	}

	var claims map[string]any
	if err := idToken.Claims(&claims); err != nil {
		return "", time.Time{}, fmt.Errorf("parse token claims: %w", err)
	}
	if username, ok := claims[o.usernameClaim].(string); ok && username != "" {
		if !ValidUsername(username) {
			return "", time.Time{}, fmt.Errorf("claim %q is not usable as a storage namespace: %q",
				o.usernameClaim, username)
		}
		return username, idToken.Expiry, nil
	}

	// The token is already trusted at this point; userinfo only fills in a
	// username claim the access token itself did not carry.
	username, err := o.fetchUserinfo(ctx, token)
	return username, idToken.Expiry, err
}

// looksLikeJWT reports whether a token is a JWS compact serialization rather
// than an opaque provider-issued string. Only the shape is inspected here; the
// signature is checked by the verifier.
func looksLikeJWT(token string) bool {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return false
	}
	header, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return false
	}
	var h struct {
		Alg string `json:"alg"`
	}
	if err := json.Unmarshal(header, &h); err != nil {
		return false
	}
	return h.Alg != ""
}

// cacheExpiry caps a cache entry at the token's own expiry so a cached identity
// never outlives the credential that produced it.
func cacheExpiry(tokenExpiry time.Time) time.Time {
	deadline := time.Now().Add(userinfoCacheTTL)
	if !tokenExpiry.IsZero() && tokenExpiry.Before(deadline) {
		return tokenExpiry
	}
	return deadline
}

// fetchUserinfo calls the provider's userinfo endpoint with the access token.
func (o *OIDCAuthenticator) fetchUserinfo(ctx context.Context, token string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", o.userinfoEndpoint, nil)
	if err != nil {
		return "", fmt.Errorf("create userinfo request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("userinfo request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("userinfo returned %d: %s", resp.StatusCode, body)
	}

	var claims map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&claims); err != nil {
		return "", fmt.Errorf("parse userinfo response: %w", err)
	}

	username, ok := claims[o.usernameClaim].(string)
	if !ok || username == "" {
		return "", fmt.Errorf("userinfo missing claim %q", o.usernameClaim)
	}
	// The provider is trusted to say who the user is, not to supply a value
	// that is safe to interpolate into an object key.
	if !ValidUsername(username) {
		return "", fmt.Errorf("claim %q is not usable as a storage namespace: %q",
			o.usernameClaim, username)
	}

	return username, nil
}
