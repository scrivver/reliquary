package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"

	"reliquary-be/config"
	"reliquary-be/handler"
)

func TestArchiveRoutesAreNotRegistered(t *testing.T) {
	router := chi.NewRouter()
	registerFileRoutes(router, &handler.Handler{})

	tests := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/api/archive"},
		{http.MethodPost, "/api/archive/restore"},
		{http.MethodPost, "/api/archive/run"},
		{http.MethodDelete, "/api/archive"},
	}

	for _, tt := range tests {
		req := httptest.NewRequest(tt.method, tt.path, nil)
		res := httptest.NewRecorder()

		router.ServeHTTP(res, req)

		if res.Code != http.StatusNotFound {
			t.Errorf("%s %s returned %d, want 404", tt.method, tt.path, res.Code)
		}
	}
}

func TestAuthConfigHandler(t *testing.T) {
	cfg := &config.Config{
		PasswordAuthEnabled: true,
		OIDCAuthEnabled:     true,
		OIDCIssuerURL:       "https://idp.example.test/application/o/reliquary/",
		OIDCClientID:        "reliquary",
		OIDCUsernameClaim:   "preferred_username",
	}
	req := httptest.NewRequest(http.MethodGet, "/api/auth/config", nil)
	res := httptest.NewRecorder()

	authConfigHandler(cfg).ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.Code)
	}

	var got authConfigResponse
	if err := json.NewDecoder(res.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if !got.Password.Enabled || !got.OIDC.Enabled {
		t.Fatalf("interactive auth providers not enabled: %+v", got)
	}
	if got.OIDC.IssuerURL != cfg.OIDCIssuerURL ||
		got.OIDC.ClientID != cfg.OIDCClientID ||
		got.OIDC.UsernameClaim != cfg.OIDCUsernameClaim {
		t.Fatalf("unexpected oidc config: %+v", got.OIDC)
	}
	if got.Proxy.Legacy != true {
		t.Fatalf("proxy should be marked legacy: %+v", got.Proxy)
	}
}
