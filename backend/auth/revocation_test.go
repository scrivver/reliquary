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

// changeOwnPassword runs a self-service password change with the given token.
func changeOwnPassword(t *testing.T, svc *Service, token, current, next string) *httptest.ResponseRecorder {
	t.Helper()

	body, _ := json.Marshal(ChangeOwnPasswordRequest{
		CurrentPassword: current,
		NewPassword:     next,
	})
	req := httptest.NewRequest(http.MethodPut, "/api/users/me/password", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	svc.Middleware(http.HandlerFunc(svc.ChangeOwnPasswordHandler)).ServeHTTP(w, req)
	return w
}

// A self-service change must end other sessions while keeping the caller's own
// client signed in, which is what the reissued token is for.
func TestChangeOwnPasswordSupersedesOtherSessions(t *testing.T) {
	users := testUserStore(t)
	seedUser(t, users, "alice", "pass", RoleUser)
	svc := NewService(testConfig(), users)
	handler := svc.Middleware(okHandler())

	other := login(t, svc, "alice", "pass")
	caller := login(t, svc, "alice", "pass")

	w := changeOwnPassword(t, svc, caller, "pass", "newpass")
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d: %s", w.Code, http.StatusOK, w.Body.String())
	}

	var resp LoginResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Token == "" {
		t.Fatal("no replacement token returned")
	}

	if code := requestStatus(t, handler, resp.Token); code != http.StatusOK {
		t.Errorf("replacement token rejected: %d", code)
	}
	if code := requestStatus(t, handler, other); code != http.StatusUnauthorized {
		t.Errorf("other session survived: %d, want %d", code, http.StatusUnauthorized)
	}
	if code := requestStatus(t, handler, caller); code != http.StatusUnauthorized {
		t.Errorf("superseded caller token survived: %d, want %d", code, http.StatusUnauthorized)
	}
}

// A stolen token must not be enough to take permanent ownership of an account.
func TestChangeOwnPasswordRequiresCurrentPassword(t *testing.T) {
	users := testUserStore(t)
	seedUser(t, users, "alice", "pass", RoleUser)
	svc := NewService(testConfig(), users)

	token := login(t, svc, "alice", "pass")

	// 403, not 401: a mistyped password must not read as an expired session and
	// sign the user out.
	if w := changeOwnPassword(t, svc, token, "wrong", "newpass"); w.Code != http.StatusForbidden {
		t.Errorf("status = %d, want %d", w.Code, http.StatusForbidden)
	}
	if w := changeOwnPassword(t, svc, token, "", "newpass"); w.Code != http.StatusBadRequest {
		t.Errorf("status for missing current password = %d, want %d", w.Code, http.StatusBadRequest)
	}
	if w := changeOwnPassword(t, svc, token, "pass", ""); w.Code != http.StatusBadRequest {
		t.Errorf("status for missing new password = %d, want %d", w.Code, http.StatusBadRequest)
	}

	// The original password must still work after the failed attempts.
	if _, err := users.Authenticate("alice", "pass"); err != nil {
		t.Errorf("password changed despite rejection: %v", err)
	}
}

func TestChangeOwnPasswordRequiresAuthentication(t *testing.T) {
	users := testUserStore(t)
	seedUser(t, users, "alice", "pass", RoleUser)
	svc := NewService(testConfig(), users)

	body, _ := json.Marshal(ChangeOwnPasswordRequest{
		CurrentPassword: "pass",
		NewPassword:     "newpass",
	})
	req := httptest.NewRequest(http.MethodPut, "/api/users/me/password", bytes.NewReader(body))
	w := httptest.NewRecorder()
	svc.Middleware(http.HandlerFunc(svc.ChangeOwnPasswordHandler)).ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
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
