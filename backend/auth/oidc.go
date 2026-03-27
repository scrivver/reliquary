package auth

import (
	"context"
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

// OIDCAuthenticator validates Bearer tokens by calling the OIDC provider's
// userinfo endpoint. This works with any token signing algorithm (HS256, RS256,
// etc.) since validation is delegated to the provider.
type OIDCAuthenticator struct {
	userinfoEndpoint string
	usernameClaim    string
	cache            sync.Map // token → *cachedUser
}

type cachedUser struct {
	username  string
	expiresAt time.Time
}

const userinfoCacheTTL = 5 * time.Minute

// NewOIDCAuthenticator discovers the provider's userinfo endpoint via OIDC discovery.
func NewOIDCAuthenticator(ctx context.Context, cfg *config.Config) (*OIDCAuthenticator, error) {
	if cfg.OIDCIssuerURL == "" {
		return nil, fmt.Errorf("OIDC_ISSUER_URL is required when AUTH_MODE=oidc")
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

	slog.Info("oidc provider discovered",
		"issuer", cfg.OIDCIssuerURL,
		"userinfo_endpoint", claims.UserinfoEndpoint,
		"username_claim", cfg.OIDCUsernameClaim,
	)

	return &OIDCAuthenticator{
		userinfoEndpoint: claims.UserinfoEndpoint,
		usernameClaim:    cfg.OIDCUsernameClaim,
	}, nil
}

// Middleware validates the Bearer token and injects username/role into context.
func (o *OIDCAuthenticator) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			http.Error(w, "missing authorization header", http.StatusUnauthorized)
			return
		}

		tokenStr := strings.TrimPrefix(authHeader, "Bearer ")
		if tokenStr == authHeader {
			http.Error(w, "invalid authorization format", http.StatusUnauthorized)
			return
		}

		username, err := o.resolveUsername(r.Context(), tokenStr)
		if err != nil {
			slog.Warn("oidc token validation failed", "error", err)
			http.Error(w, "invalid token", http.StatusUnauthorized)
			return
		}

		ctx := context.WithValue(r.Context(), ctxUsername, username)
		ctx = context.WithValue(ctx, ctxRole, RoleUser)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
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

	username, err := o.fetchUserinfo(ctx, token)
	if err != nil {
		return "", err
	}

	o.cache.Store(token, &cachedUser{
		username:  username,
		expiresAt: time.Now().Add(userinfoCacheTTL),
	})

	return username, nil
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

	return username, nil
}
