package auth

import (
	"context"
	"crypto/subtle"
	"log/slog"
	"net/http"
)

const (
	proxyUserHeader   = "X-Reliquary-User"
	proxySecretHeader = "X-Reliquary-Proxy-Secret"
)

// ProxyMiddleware authenticates using the identity asserted by a trusted
// upstream proxy in the X-Reliquary-User header.
//
// The upstream must prove it is the upstream by presenting sharedSecret in
// X-Reliquary-Proxy-Secret; otherwise the identity header is attacker
// controlled and must not be believed. An empty sharedSecret disables that
// proof and is only reachable via AUTH_PROXY_INSECURE_TRUST_HEADER, for
// deployments where the API is reachable only from the proxy.
//
// There is no default-user fallback: a request without a usable identity is
// rejected rather than silently promoted to the configured admin.
func ProxyMiddleware(sharedSecret string) func(http.Handler) http.Handler {
	secret := []byte(sharedSecret)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if len(secret) > 0 {
				got := []byte(r.Header.Get(proxySecretHeader))
				if subtle.ConstantTimeCompare(got, secret) != 1 {
					slog.Warn("proxy auth denied: bad or missing proxy secret", "remote", r.RemoteAddr)
					http.Error(w, "unauthorized", http.StatusUnauthorized)
					return
				}
			}

			username := r.Header.Get(proxyUserHeader)
			if !ValidUsername(username) {
				slog.Warn("proxy auth denied: missing or invalid user header", "remote", r.RemoteAddr)
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}

			next.ServeHTTP(w, r.WithContext(WithIdentity(r.Context(), username, RoleUser)))
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
