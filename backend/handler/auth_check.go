package handler

import (
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"

	"reliquary-be/auth"
)

// AuthCheck authorizes /storage/* downloads at the edge. Caddy's forward_auth
// directive proxies every request to this endpoint before streaming the object
// from MinIO; a 2xx response lets Caddy continue, any other status is returned
// to the client unchanged. The original request URI arrives in the
// X-Forwarded-Uri header.
//
// GET /api/auth/check
func (h *Handler) AuthCheck(w http.ResponseWriter, r *http.Request) {
	username := auth.UsernameFromContext(r.Context())

	key, err := objectKeyFromStorageURI(r.Header.Get("X-Forwarded-Uri"), h.bucket)
	if err != nil {
		slog.Warn("download auth check rejected bad path", "user", username, "error", err)
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	if username == "" || !UserOwnsKey(username, key) {
		slog.Warn("download auth check denied", "user", username, "key", key, "remote", r.RemoteAddr)
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	slog.Info("download authorized", "user", username, "key", key, "remote", r.RemoteAddr)
	w.WriteHeader(http.StatusNoContent)
}

// objectKeyFromStorageURI extracts the object key from a /storage/... request
// URI as forwarded by Caddy. Presigned download URLs use the layout
// /storage/<bucket>/<key>, so both the /storage prefix and the bucket segment
// are stripped to recover the app-level key (e.g. "files/alice/2026/06/a.jpg").
func objectKeyFromStorageURI(rawURI, bucket string) (string, error) {
	if rawURI == "" {
		return "", fmt.Errorf("missing X-Forwarded-Uri")
	}
	u, err := url.Parse(rawURI)
	if err != nil {
		return "", fmt.Errorf("parse storage uri: %w", err)
	}
	p := strings.TrimPrefix(u.Path, "/storage")
	p = strings.TrimPrefix(p, "/")
	if bucket != "" {
		p = strings.TrimPrefix(p, bucket+"/")
	}
	if p == "" {
		return "", fmt.Errorf("no object key in %q", rawURI)
	}
	return p, nil
}
