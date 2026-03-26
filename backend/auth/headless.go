package auth

import (
	"context"
	"net/http"
)

const proxyUserHeader = "X-Reliquary-User"

// ProxyMiddleware trusts the X-Reliquary-User header for user identity.
// Used when AUTH_MODE=proxy — the upstream proxy handles authentication.
func ProxyMiddleware(defaultUser string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			username := r.Header.Get(proxyUserHeader)
			if username == "" {
				username = defaultUser
			}

			ctx := context.WithValue(r.Context(), ctxUsername, username)
			ctx = context.WithValue(ctx, ctxRole, RoleUser)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// NoAuthMiddleware injects a fixed default user for all requests.
// Used when AUTH_MODE=none — single user, no authentication.
func NoAuthMiddleware(defaultUser string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ctx := context.WithValue(r.Context(), ctxUsername, defaultUser)
			ctx = context.WithValue(ctx, ctxRole, RoleAdmin)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}
