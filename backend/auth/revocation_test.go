package auth

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// login returns a freshly issued token for the given credentials.
func login(t *testing.T, svc *Service, username, password string) string {
	t.Helper()

	body, _ := json.Marshal(LoginRequest{Username: username, Password: password})
	req := httptest.NewRequest(http.MethodPost, "/api/login", bytes.NewReader(body))
	w := httptest.NewRecorder()
	svc.LoginHandler(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("login failed: %d %s", w.Code, w.Body.String())
	}

	var resp LoginResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode login response: %v", err)
	}
	return resp.Token
}

// requestStatus runs one authenticated request through the given middleware
// chain and reports the resulting status code.
func requestStatus(t *testing.T, handler http.Handler, token string) int {
	t.Helper()

	req := httptest.NewRequest(http.MethodGet, "/api/files", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	return w.Code
}

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
}

// Deactivating an account must end its existing sessions, not merely stop new
// logins. The same check guards /storage/* through /api/auth/check.
func TestTokenRejectedAfterDeactivation(t *testing.T) {
	users := testUserStore(t)
	seedUser(t, users, "alice", "pass", RoleUser)
	svc := NewService(testConfig(), users)
	handler := svc.Middleware(okHandler())

	token := login(t, svc, "alice", "pass")
	if code := requestStatus(t, handler, token); code != http.StatusOK {
		t.Fatalf("token rejected before deactivation: %d", code)
	}

	if err := users.Deactivate(t.Context(), "alice"); err != nil {
		t.Fatalf("Deactivate: %v", err)
	}

	if code := requestStatus(t, handler, token); code != http.StatusUnauthorized {
		t.Errorf("status after deactivation = %d, want %d", code, http.StatusUnauthorized)
	}
}

func TestTokenRejectedAfterDeletion(t *testing.T) {
	users := testUserStore(t)
	seedUser(t, users, "alice", "pass", RoleUser)
	svc := NewService(testConfig(), users)
	handler := svc.Middleware(okHandler())

	token := login(t, svc, "alice", "pass")
	if err := users.Delete(t.Context(), "alice"); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	if code := requestStatus(t, handler, token); code != http.StatusUnauthorized {
		t.Errorf("status after deletion = %d, want %d", code, http.StatusUnauthorized)
	}
}

// Changing a password is how a user ends sessions they no longer trust, so
// tokens issued before it must stop working — while a login immediately after
// must still succeed.
func TestTokenRejectedAfterPasswordChange(t *testing.T) {
	users := testUserStore(t)
	seedUser(t, users, "alice", "pass", RoleUser)
	svc := NewService(testConfig(), users)
	handler := svc.Middleware(okHandler())

	old := login(t, svc, "alice", "pass")

	if err := users.ChangePassword(t.Context(), "alice", "newpass"); err != nil {
		t.Fatalf("ChangePassword: %v", err)
	}

	if code := requestStatus(t, handler, old); code != http.StatusUnauthorized {
		t.Errorf("status for pre-change token = %d, want %d", code, http.StatusUnauthorized)
	}

	// A version bump orders the two tokens exactly, so a login in the same
	// second as the change is still accepted.
	fresh := login(t, svc, "alice", "newpass")
	if code := requestStatus(t, handler, fresh); code != http.StatusOK {
		t.Errorf("status for post-change token = %d, want %d", code, http.StatusOK)
	}
}

// The role in the claim is a snapshot from login; the stored role is current.
func TestRoleComesFromStoreNotClaim(t *testing.T) {
	users := testUserStore(t)
	seedUser(t, users, "alice", "pass", RoleAdmin)
	svc := NewService(testConfig(), users)
	handler := svc.Middleware(svc.AdminMiddleware(okHandler()))

	token := login(t, svc, "alice", "pass")
	if code := requestStatus(t, handler, token); code != http.StatusOK {
		t.Fatalf("admin rejected before demotion: %d", code)
	}

	// Demote without touching the already-issued token.
	users.mu.Lock()
	user := users.users["alice"]
	user.Role = RoleUser
	users.users["alice"] = user
	users.mu.Unlock()

	if code := requestStatus(t, handler, token); code != http.StatusForbidden {
		t.Errorf("status after demotion = %d, want %d", code, http.StatusForbidden)
	}
}

// Accounts and tokens predating this change both carry version 0, so existing
// sessions must survive the upgrade.
func TestTokenAcceptedAtDefaultVersion(t *testing.T) {
	users := testUserStore(t)
	seedUser(t, users, "alice", "pass", RoleUser)
	svc := NewService(testConfig(), users)
	handler := svc.Middleware(okHandler())

	if user, _ := users.Get("alice"); user.TokenVersion != 0 {
		t.Fatalf("seeded user has version %d, want 0", user.TokenVersion)
	}

	token := login(t, svc, "alice", "pass")
	if code := requestStatus(t, handler, token); code != http.StatusOK {
		t.Errorf("status = %d, want %d", code, http.StatusOK)
	}
}

// Each bump supersedes only the sessions that came before it.
func TestTokenVersionAdvancesPerChange(t *testing.T) {
	users := testUserStore(t)
	seedUser(t, users, "alice", "pass", RoleUser)
	svc := NewService(testConfig(), users)
	handler := svc.Middleware(okHandler())

	if err := users.ChangePassword(t.Context(), "alice", "second"); err != nil {
		t.Fatalf("ChangePassword: %v", err)
	}
	first := login(t, svc, "alice", "second")

	if err := users.ChangePassword(t.Context(), "alice", "third"); err != nil {
		t.Fatalf("ChangePassword: %v", err)
	}
	second := login(t, svc, "alice", "third")

	if code := requestStatus(t, handler, first); code != http.StatusUnauthorized {
		t.Errorf("status for superseded token = %d, want %d", code, http.StatusUnauthorized)
	}
	if code := requestStatus(t, handler, second); code != http.StatusOK {
		t.Errorf("status for current token = %d, want %d", code, http.StatusOK)
	}

	if user, _ := users.Get("alice"); user.TokenVersion != 2 {
		t.Errorf("TokenVersion = %d, want 2", user.TokenVersion)
	}
}
