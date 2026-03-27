package auth

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"

	"reliquary-be/config"
)

// OIDCAuthenticator validates Bearer tokens against an OIDC provider.
type OIDCAuthenticator struct {
	verifier      *oidc.IDTokenVerifier
	usernameClaim string
}

// NewOIDCAuthenticator creates an OIDC authenticator by discovering the provider's JWKS endpoint.
func NewOIDCAuthenticator(ctx context.Context, cfg *config.Config) (*OIDCAuthenticator, error) {
	if cfg.OIDCIssuerURL == "" {
		return nil, fmt.Errorf("OIDC_ISSUER_URL is required when AUTH_MODE=oidc")
	}
	if cfg.OIDCClientID == "" {
		return nil, fmt.Errorf("OIDC_CLIENT_ID is required when AUTH_MODE=oidc")
	}

	provider, err := oidc.NewProvider(ctx, cfg.OIDCIssuerURL)
	if err != nil {
		return nil, fmt.Errorf("oidc discovery: %w", err)
	}

	verifier := provider.Verifier(&oidc.Config{
		ClientID: cfg.OIDCClientID,
	})

	slog.Info("oidc provider discovered",
		"issuer", cfg.OIDCIssuerURL,
		"client_id", cfg.OIDCClientID,
		"username_claim", cfg.OIDCUsernameClaim,
	)

	return &OIDCAuthenticator{
		verifier:      verifier,
		usernameClaim: cfg.OIDCUsernameClaim,
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

		idToken, err := o.verifier.Verify(r.Context(), tokenStr)
		if err != nil {
			slog.Debug("oidc token verification failed", "error", err)
			http.Error(w, "invalid token", http.StatusUnauthorized)
			return
		}

		var claims map[string]any
		if err := idToken.Claims(&claims); err != nil {
			http.Error(w, "failed to parse token claims", http.StatusUnauthorized)
			return
		}

		username, ok := claims[o.usernameClaim].(string)
		if !ok || username == "" {
			http.Error(w, fmt.Sprintf("token missing claim %q", o.usernameClaim), http.StatusUnauthorized)
			return
		}

		ctx := context.WithValue(r.Context(), ctxUsername, username)
		ctx = context.WithValue(ctx, ctxRole, RoleUser)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
