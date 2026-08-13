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

// objectKeyFromStorageURI extracts the object key from the request URI Caddy
// forwards for a /storage/... download, recovering the app-level key (e.g.
// "files/alice/2026/06/a.jpg").
//
// Caddy applies its own directive ordering rather than the Caddyfile's, and
// `uri strip_prefix /storage` sorts ahead of `forward_auth`. The URI therefore
// arrives as /<bucket>/<key>, already stripped. The /storage/<bucket>/<key>
// form is accepted too so this does not silently break if that ordering
// changes or an operator wraps the directives in an explicit route.
//
// The bucket segment is required rather than optimistically trimmed: it is the
// only structural anchor in the path, and a TrimPrefix that silently no-ops
// returns a key naming a different object than the request does — which is
// then handed to the ownership check as if it were the real one.
func objectKeyFromStorageURI(rawURI, bucket string) (string, error) {
	if rawURI == "" {
		return "", fmt.Errorf("missing X-Forwarded-Uri")
	}
	if bucket == "" {
		return "", fmt.Errorf("no bucket configured to anchor %q", rawURI)
	}
	u, err := url.Parse(rawURI)
	if err != nil {
		return "", fmt.Errorf("parse storage uri: %w", err)
	}
	// Match the bucket before considering the unstripped form, so a bucket
	// literally named "storage" is not mistaken for the prefix.
	key, ok := strings.CutPrefix(u.Path, "/"+bucket+"/")
	if !ok {
		key, ok = strings.CutPrefix(u.Path, "/storage/"+bucket+"/")
	}
	if !ok {
		return "", fmt.Errorf("path is not under bucket %q: %q", bucket, rawURI)
	}
	if !validObjectKey(key) {
		return "", fmt.Errorf("object key is not canonical: %q", key)
	}
	return key, nil
}
