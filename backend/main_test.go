package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"

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
