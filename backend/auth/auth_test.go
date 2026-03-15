package auth

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"golang.org/x/crypto/bcrypt"

	"reliquary-be/config"
)

func testConfig() *config.Config {
	return &config.Config{
		JWTSecret: "test-secret",
		Username:  "admin",
		Password:  "admin",
	}
}

func testUserStore(t *testing.T) *UserStore {
	t.Helper()
	// Create a minimal in-memory user store (no MinIO).
	store := &UserStore{users: make(map[string]User)}
	return store
}

func seedUser(t *testing.T, store *UserStore, username, password string, role Role) {
	t.Helper()
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		t.Fatal(err)
	}
	store.users[username] = User{PasswordHash: string(hash), Role: role}
}

func TestLoginHandler_Success(t *testing.T) {
	cfg := testConfig()
	users := testUserStore(t)
	seedUser(t, users, "admin", "admin", RoleAdmin)
	svc := NewService(cfg, users)

	body, _ := json.Marshal(LoginRequest{Username: "admin", Password: "admin"})
	req := httptest.NewRequest("POST", "/api/login", bytes.NewReader(body))
	w := httptest.NewRecorder()

	svc.LoginHandler(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp LoginResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	if resp.Token == "" {
		t.Error("expected non-empty token")
	}
	if resp.Username != "admin" {
		t.Errorf("expected username admin, got %s", resp.Username)
	}
	if resp.Role != "admin" {
		t.Errorf("expected role admin, got %s", resp.Role)
	}
}

func TestLoginHandler_InvalidPassword(t *testing.T) {
	cfg := testConfig()
	users := testUserStore(t)
	seedUser(t, users, "admin", "admin", RoleAdmin)
	svc := NewService(cfg, users)

	body, _ := json.Marshal(LoginRequest{Username: "admin", Password: "wrong"})
	req := httptest.NewRequest("POST", "/api/login", bytes.NewReader(body))
	w := httptest.NewRecorder()

	svc.LoginHandler(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", w.Code)
	}
}

func TestLoginHandler_UnknownUser(t *testing.T) {
	cfg := testConfig()
	users := testUserStore(t)
	svc := NewService(cfg, users)

	body, _ := json.Marshal(LoginRequest{Username: "nobody", Password: "pass"})
	req := httptest.NewRequest("POST", "/api/login", bytes.NewReader(body))
	w := httptest.NewRecorder()

	svc.LoginHandler(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", w.Code)
	}
}

func TestMiddleware_ValidToken(t *testing.T) {
	cfg := testConfig()
	users := testUserStore(t)
	seedUser(t, users, "alice", "pass", RoleUser)
	svc := NewService(cfg, users)

	// Login to get a token.
	body, _ := json.Marshal(LoginRequest{Username: "alice", Password: "pass"})
	loginReq := httptest.NewRequest("POST", "/api/login", bytes.NewReader(body))
	loginW := httptest.NewRecorder()
	svc.LoginHandler(loginW, loginReq)

	var resp LoginResponse
	json.NewDecoder(loginW.Body).Decode(&resp)

	// Use the token in a protected request.
	var gotUsername string
	var gotRole Role
	handler := svc.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotUsername = UsernameFromContext(r.Context())
		gotRole = RoleFromContext(r.Context())
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("GET", "/api/files", nil)
	req.Header.Set("Authorization", "Bearer "+resp.Token)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	if gotUsername != "alice" {
		t.Errorf("expected username alice, got %s", gotUsername)
	}
	if gotRole != RoleUser {
		t.Errorf("expected role user, got %s", gotRole)
	}
}

func TestMiddleware_MissingToken(t *testing.T) {
	cfg := testConfig()
	users := testUserStore(t)
	svc := NewService(cfg, users)

	handler := svc.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler should not be called")
	}))

	req := httptest.NewRequest("GET", "/api/files", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", w.Code)
	}
}

func TestMiddleware_InvalidToken(t *testing.T) {
	cfg := testConfig()
	users := testUserStore(t)
	svc := NewService(cfg, users)

	handler := svc.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler should not be called")
	}))

	req := httptest.NewRequest("GET", "/api/files", nil)
	req.Header.Set("Authorization", "Bearer invalid-token")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", w.Code)
	}
}

func TestAdminMiddleware_AllowsAdmin(t *testing.T) {
	cfg := testConfig()
	users := testUserStore(t)
	seedUser(t, users, "admin", "pass", RoleAdmin)
	svc := NewService(cfg, users)

	// Login as admin.
	body, _ := json.Marshal(LoginRequest{Username: "admin", Password: "pass"})
	loginReq := httptest.NewRequest("POST", "/api/login", bytes.NewReader(body))
	loginW := httptest.NewRecorder()
	svc.LoginHandler(loginW, loginReq)
	var resp LoginResponse
	json.NewDecoder(loginW.Body).Decode(&resp)

	called := false
	handler := svc.Middleware(svc.AdminMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	})))

	req := httptest.NewRequest("GET", "/api/admin/users", nil)
	req.Header.Set("Authorization", "Bearer "+resp.Token)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if !called {
		t.Error("admin handler should have been called")
	}
}

func TestAdminMiddleware_RejectsUser(t *testing.T) {
	cfg := testConfig()
	users := testUserStore(t)
	seedUser(t, users, "bob", "pass", RoleUser)
	svc := NewService(cfg, users)

	body, _ := json.Marshal(LoginRequest{Username: "bob", Password: "pass"})
	loginReq := httptest.NewRequest("POST", "/api/login", bytes.NewReader(body))
	loginW := httptest.NewRecorder()
	svc.LoginHandler(loginW, loginReq)
	var resp LoginResponse
	json.NewDecoder(loginW.Body).Decode(&resp)

	handler := svc.Middleware(svc.AdminMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("handler should not be called for non-admin")
	})))

	req := httptest.NewRequest("GET", "/api/admin/users", nil)
	req.Header.Set("Authorization", "Bearer "+resp.Token)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", w.Code)
	}
}
