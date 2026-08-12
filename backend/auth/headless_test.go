package auth

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// proxyRequest builds a request carrying the given identity and secret headers.
// An empty value means the header is omitted entirely.
func proxyRequest(user, secret string) *http.Request {
	req := httptest.NewRequest(http.MethodGet, "/api/files", nil)
	if user != "" {
		req.Header.Set(proxyUserHeader, user)
	}
	if secret != "" {
		req.Header.Set(proxySecretHeader, secret)
	}
	return req
}

func TestProxyMiddlewareRequiresSharedSecret(t *testing.T) {
	tests := []struct {
		name     string
		user     string
		secret   string
		wantCode int
		wantUser string
	}{
		{"valid pair", "alice", "s3cret", http.StatusOK, "alice"},
		{"missing secret", "alice", "", http.StatusUnauthorized, ""},
		{"wrong secret", "alice", "nope", http.StatusUnauthorized, ""},
		{"secret prefix only", "alice", "s3cre", http.StatusUnauthorized, ""},
		{"missing user", "", "s3cret", http.StatusUnauthorized, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var gotUser string
			next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				gotUser = UsernameFromContext(r.Context())
			})

			res := httptest.NewRecorder()
			ProxyMiddleware("s3cret")(next).ServeHTTP(res, proxyRequest(tt.user, tt.secret))

			if res.Code != tt.wantCode {
				t.Errorf("status = %d, want %d", res.Code, tt.wantCode)
			}
			if gotUser != tt.wantUser {
				t.Errorf("username = %q, want %q", gotUser, tt.wantUser)
			}
		})
	}
}

// A missing identity header must be rejected, never promoted to a default user.
func TestProxyMiddlewareHasNoDefaultUserFallback(t *testing.T) {
	called := false
	next := http.HandlerFunc(func(http.ResponseWriter, *http.Request) { called = true })

	res := httptest.NewRecorder()
	ProxyMiddleware("")(next).ServeHTTP(res, proxyRequest("", ""))

	if res.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", res.Code, http.StatusUnauthorized)
	}
	if called {
		t.Error("handler ran without an asserted identity")
	}
}

// The username becomes an object key prefix, so values that could escape the
// caller's namespace must be rejected even when the secret checks out.
func TestProxyMiddlewareRejectsUnsafeUsernames(t *testing.T) {
	unsafe := []string{
		"../admin",
		"alice/../bob",
		"alice/",
		"alice bob",
		"alice\n",
		"",
	}

	for _, username := range unsafe {
		t.Run(username, func(t *testing.T) {
			called := false
			next := http.HandlerFunc(func(http.ResponseWriter, *http.Request) { called = true })

			req := httptest.NewRequest(http.MethodGet, "/api/files", nil)
			// Set directly: header values with control characters are rejected
			// by Header.Set's canonicalization path in some cases.
			req.Header[proxyUserHeader] = []string{username}
			req.Header.Set(proxySecretHeader, "s3cret")

			res := httptest.NewRecorder()
			ProxyMiddleware("s3cret")(next).ServeHTTP(res, req)

			if res.Code != http.StatusUnauthorized {
				t.Errorf("username %q: status = %d, want %d", username, res.Code, http.StatusUnauthorized)
			}
			if called {
				t.Errorf("username %q: handler ran", username)
			}
		})
	}
}

func TestProxyMiddlewareInsecureModeAcceptsUserWithoutSecret(t *testing.T) {
	var gotUser string
	var gotRole Role
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotUser = UsernameFromContext(r.Context())
		gotRole = RoleFromContext(r.Context())
	})

	res := httptest.NewRecorder()
	ProxyMiddleware("")(next).ServeHTTP(res, proxyRequest("alice", ""))

	if res.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", res.Code, http.StatusOK)
	}
	if gotUser != "alice" {
		t.Errorf("username = %q, want %q", gotUser, "alice")
	}
	// Proxy identities never carry admin rights.
	if gotRole != RoleUser {
		t.Errorf("role = %q, want %q", gotRole, RoleUser)
	}
}
