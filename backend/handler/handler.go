package handler

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"

	"reliquary-be/auth"
	"reliquary-be/config"
	"reliquary-be/event"
	"reliquary-be/storage"
	"reliquary-be/thumbnail"

	"github.com/minio/minio-go/v7"
)

type fileStore interface {
	StatObject(ctx context.Context, key string) (minio.ObjectInfo, error)
	PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string, userMeta map[string]string) error
	PresignGet(ctx context.Context, key string, forceDownload bool) (*url.URL, error)
	GetObject(ctx context.Context, key string) (io.ReadCloser, error)
	DeleteObject(ctx context.Context, key string) error
	ComputeUserStats(ctx context.Context, username string) (storage.UserStats, error)
	ListObjects(ctx context.Context, prefix string) ([]minio.ObjectInfo, error)
}

type checksumIndex interface {
	LoadUser(ctx context.Context, username string) error
	Lookup(username, checksum string) string
	Add(ctx context.Context, username, checksum, key string) error
	RemoveByKey(ctx context.Context, username, key string) error
}

type Handler struct {
	store        fileStore
	thumbs       thumbnail.Publisher
	checksums    checksumIndex
	events       event.Emitter
	deviceName   string
	proxyBaseURL string
}

func New(
	cfg *config.Config,
	store *storage.Client,
	thumbs thumbnail.Publisher,
	checksums *storage.ChecksumIndex,
	events event.Emitter,
) *Handler {
	return &Handler{
		store:        store,
		thumbs:       thumbs,
		checksums:    checksums,
		events:       events,
		deviceName:   cfg.EventDeviceName,
		proxyBaseURL: cfg.ProxyBaseURL,
	}
}

// --- Request / Response types ---

type UploadResponse struct {
	Key       string `json:"key"`
	Size      int64  `json:"size"`
	Duplicate bool   `json:"duplicate,omitempty"`
	Warning   string `json:"warning,omitempty"`
}

type FileItem struct {
	Key          string    `json:"key"`
	Size         int64     `json:"size"`
	ContentType  string    `json:"content_type"`
	LastModified time.Time `json:"last_modified"`
	ThumbnailKey string    `json:"thumbnail_key,omitempty"`
	Checksum     string    `json:"checksum,omitempty"`
	UploadDate   string    `json:"upload_date,omitempty"`
	OriginalName string    `json:"original_name,omitempty"`
}

type FileListResponse struct {
	Files      []FileItem `json:"files"`
	TotalCount int        `json:"total_count"`
	Offset     int        `json:"offset"`
	Limit      int        `json:"limit"`
}

type PresignDownloadResponse struct {
	URL string `json:"url"`
}

type BatchDownloadRequest struct {
	Keys []string `json:"keys"`
}

// --- Handlers ---

// Upload handles multipart file upload, stores the file in MinIO, and
// triggers thumbnail generation.
// POST /api/upload
func (h *Handler) Upload(w http.ResponseWriter, r *http.Request) {
	username := auth.UsernameFromContext(r.Context())

	if err := r.ParseMultipartForm(32 << 20); err != nil {
		httpError(w, "failed to parse multipart form", http.StatusBadRequest)
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		httpError(w, "file field is required", http.StatusBadRequest)
		return
	}
	defer file.Close()

	filename := sanitizeFilename(header.Filename)
	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}

	// Optional relative path for folder uploads (e.g., "Photos/Vacation/img.jpg").
	relativePath := r.FormValue("path")
	storedName := filename
	if relativePath != "" {
		storedName = sanitizePath(relativePath)
	}

	now := time.Now()
	baseName := strings.TrimSuffix(storedName, path.Ext(storedName))
	ext := path.Ext(storedName)
	fileKey := fmt.Sprintf("files/%s/%d/%02d/%s", username, now.Year(), now.Month(), storedName)

	// Avoid overwriting existing files by appending a suffix.
	for i := 1; ; i++ {
		_, err := h.store.StatObject(r.Context(), fileKey)
		if err != nil {
			break
		}
		fileKey = fmt.Sprintf("files/%s/%d/%02d/%s_%d%s", username, now.Year(), now.Month(), baseName, i, ext)
	}

	data, err := io.ReadAll(file)
	if err != nil {
		httpError(w, "failed to read file", http.StatusInternalServerError)
		return
	}

	hash := sha256.Sum256(data)
	checksum := hex.EncodeToString(hash[:])

	// Ensure user's checksum index is loaded.
	h.checksums.LoadUser(r.Context(), username)

	// Check for duplicate by checksum.
	if existingKey := h.checksums.Lookup(username, checksum); existingKey != "" {
		slog.Info("duplicate detected", "checksum", checksum, "existing_key", existingKey)
		stat, err := h.store.StatObject(r.Context(), existingKey)
		if err != nil {
			slog.Error("failed to stat duplicate file", "key", existingKey, "error", err)
			httpError(w, "failed to inspect existing file", http.StatusInternalServerError)
			return
		}
		existingContentType := stat.ContentType
		if existingContentType == "" {
			existingContentType = contentType
		}
		warning, err := h.publishUploadEffects(
			r.Context(),
			existingKey,
			existingContentType,
			checksum,
		)
		if err != nil {
			slog.Error("failed to republish upload effects", "key", existingKey, "error", err)
			httpError(w, "file exists but background work could not be published; retry upload", http.StatusServiceUnavailable)
			return
		}
		jsonResponse(w, UploadResponse{Key: existingKey, Size: int64(len(data)), Duplicate: true, Warning: warning})
		return
	}

	meta := map[string]string{
		"Checksum":      checksum,
		"Upload-Date":   now.UTC().Format(time.RFC3339),
		"Original-Name": header.Filename,
		"Owner":         username,
	}

	if err := h.store.PutObject(r.Context(), fileKey, bytes.NewReader(data), int64(len(data)), contentType, meta); err != nil {
		slog.Error("upload to minio failed", "key", fileKey, "error", err)
		httpError(w, "failed to store file", http.StatusInternalServerError)
		return
	}

	slog.Info("file uploaded", "key", fileKey, "size", len(data), "checksum", checksum)

	if err := h.checksums.Add(r.Context(), username, checksum, fileKey); err != nil {
		slog.Error("failed to update checksum index", "error", err)
	}

	warning, err := h.publishUploadEffects(r.Context(), fileKey, contentType, checksum)
	if err != nil {
		slog.Error("failed to publish upload effects", "key", fileKey, "error", err)
		httpError(w, "file stored but background work could not be published; retry upload", http.StatusServiceUnavailable)
		return
	}

	jsonResponse(w, UploadResponse{Key: fileKey, Size: header.Size, Warning: warning})
}

// ListFiles returns files with pagination support.
// GET /api/files?offset=0&limit=50
func (h *Handler) ListFiles(w http.ResponseWriter, r *http.Request) {
	username := auth.UsernameFromContext(r.Context())
	h.listObjectsWithPagination(w, r, "files/"+username+"/", "files/", "thumbs/")
}

// PresignDownload generates a presigned GET URL routed through the reverse proxy.
// GET /api/files/presign?key=...
func (h *Handler) PresignDownload(w http.ResponseWriter, r *http.Request) {
	username := auth.UsernameFromContext(r.Context())
	key := r.URL.Query().Get("key")
	if key == "" {
		httpError(w, "key query parameter is required", http.StatusBadRequest)
		return
	}
	if !userOwnsKey(username, key) {
		httpError(w, "forbidden", http.StatusForbidden)
		return
	}

	download := r.URL.Query().Get("download") == "true"

	presignedURL, err := h.store.PresignGet(r.Context(), key, download)
	if err != nil {
		slog.Error("presign get failed", "key", key, "error", err)
		httpError(w, "failed to generate download URL", http.StatusInternalServerError)
		return
	}

	// Return a relative path so clients can prepend their own server URL.
	relativeURL := "/storage" + presignedURL.Path
	if presignedURL.RawQuery != "" {
		relativeURL += "?" + presignedURL.RawQuery
	}

	jsonResponse(w, PresignDownloadResponse{URL: relativeURL})
}

// BatchDownload creates a zip archive of the requested files and streams it.
// POST /api/files/download
func (h *Handler) BatchDownload(w http.ResponseWriter, r *http.Request) {
	username := auth.UsernameFromContext(r.Context())
	var req BatchDownloadRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if len(req.Keys) == 0 {
		httpError(w, "no files specified", http.StatusBadRequest)
		return
	}
	for _, key := range req.Keys {
		if !userOwnsKey(username, key) {
			httpError(w, "forbidden", http.StatusForbidden)
			return
		}
	}

	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="reliquary-download.zip"`)

	zipWriter := zip.NewWriter(w)
	defer zipWriter.Close()

	for _, key := range req.Keys {
		obj, err := h.store.GetObject(r.Context(), key)
		if err != nil {
			slog.Error("batch download: failed to get object", "key", key, "error", err)
			continue
		}

		// Use just the filename part for the zip entry.
		parts := strings.Split(key, "/")
		name := parts[len(parts)-1]

		entry, err := zipWriter.Create(name)
		if err != nil {
			obj.Close()
			slog.Error("batch download: failed to create zip entry", "key", key, "error", err)
			continue
		}

		if _, err := io.Copy(entry, obj); err != nil {
			obj.Close()
			slog.Error("batch download: failed to write zip entry", "key", key, "error", err)
			continue
		}
		obj.Close()
	}
}

// DeleteFile removes a file and its thumbnail from MinIO.
// DELETE /api/files?key=...
func (h *Handler) DeleteFile(w http.ResponseWriter, r *http.Request) {
	username := auth.UsernameFromContext(r.Context())
	key := r.URL.Query().Get("key")
	if key == "" {
		httpError(w, "key query parameter is required", http.StatusBadRequest)
		return
	}
	if !userOwnsKey(username, key) {
		httpError(w, "forbidden", http.StatusForbidden)
		return
	}

	if err := h.store.DeleteObject(r.Context(), key); err != nil {
		slog.Error("delete object failed", "key", key, "error", err)
		httpError(w, "failed to delete file", http.StatusInternalServerError)
		return
	}

	if err := h.checksums.RemoveByKey(r.Context(), username, key); err != nil {
		slog.Error("failed to update checksum index on delete", "error", err)
	}

	thumbKey := fileKeyToThumbKey(key)
	if thumbKey != "" {
		h.store.DeleteObject(r.Context(), thumbKey)
	}

	if err := h.emitDelete(r.Context(), key); err != nil {
		slog.Error("failed to publish delete event", "key", key, "error", err)
		httpError(w, "file deleted but its event could not be published; retry delete", http.StatusServiceUnavailable)
		return
	}

	jsonResponse(w, map[string]string{"status": "deleted"})
}

func (h *Handler) emitDelete(ctx context.Context, key string) error {
	return h.events.Emit(ctx, event.FileEvent{
		Event:       event.Delete,
		FilePath:    key,
		Filename:    path.Base(key),
		DeviceName:  h.deviceName,
		StorageType: event.StorageS3,
	})
}

func (h *Handler) emitCreate(ctx context.Context, key, checksum string) error {
	stat, err := h.store.StatObject(ctx, key)
	if err != nil {
		return fmt.Errorf("stat uploaded object: %w", err)
	}
	return h.events.Emit(ctx, event.FileEvent{
		Event:       event.Create,
		FilePath:    key,
		Filename:    path.Base(key),
		Size:        stat.Size,
		Hash:        "sha256:" + checksum,
		Mtime:       stat.LastModified.UTC().Format(time.RFC3339),
		DeviceName:  h.deviceName,
		StorageType: event.StorageS3,
	})
}

func (h *Handler) publishUploadEffects(
	ctx context.Context,
	key string,
	contentType string,
	checksum string,
) (string, error) {
	var warning string
	if thumbnail.SupportedContentType(contentType) {
		if err := h.thumbs.Publish(ctx, thumbnail.Job{
			Version:     thumbnail.JobVersion,
			FileKey:     key,
			ContentType: contentType,
			Checksum:    checksum,
		}); err != nil {
			slog.Warn("thumbnail job could not be published", "key", key, "error", err)
			warning = "thumbnail generation is pending because background work is unavailable"
		}
	}
	if err := h.emitCreate(ctx, key, checksum); err != nil {
		return warning, fmt.Errorf("publish create event: %w", err)
	}
	return warning, nil
}

// --- Admin handlers ---

type CreateUserRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Role     string `json:"role"`
}

type UserInfo struct {
	Username      string `json:"username"`
	Role          string `json:"role"`
	CreatedAt     string `json:"created_at"`
	DeactivatedAt string `json:"deactivated_at,omitempty"`
	Deactivated   bool   `json:"deactivated,omitempty"`
}

type ChangePasswordRequest struct {
	Password string `json:"password"`
}

func NewAdminHandler(users *auth.UserStore, store *storage.Client) *AdminHandler {
	return &AdminHandler{users: users, store: store}
}

type AdminHandler struct {
	users *auth.UserStore
	store *storage.Client
}

// CreateUser creates a new user.
// POST /api/admin/users
func (ah *AdminHandler) CreateUser(w http.ResponseWriter, r *http.Request) {
	var req CreateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.Username == "" || req.Password == "" {
		httpError(w, "username and password are required", http.StatusBadRequest)
		return
	}
	if req.Role == "admin" {
		httpError(w, "admin users must be created during initialization or by command-line tooling", http.StatusForbidden)
		return
	}

	if err := ah.users.Create(r.Context(), req.Username, req.Password, auth.RoleUser); err != nil {
		httpError(w, err.Error(), http.StatusConflict)
		return
	}

	jsonResponse(w, map[string]string{"status": "created", "username": req.Username})
}

// ListUsers returns all users.
// GET /api/admin/users
func (ah *AdminHandler) ListUsers(w http.ResponseWriter, r *http.Request) {
	users := ah.users.List()
	result := make([]UserInfo, 0, len(users))
	for name, u := range users {
		info := UserInfo{
			Username:  name,
			Role:      string(u.Role),
			CreatedAt: u.CreatedAt.Format(time.RFC3339),
		}
		if u.DeactivatedAt != nil {
			info.Deactivated = true
			info.DeactivatedAt = u.DeactivatedAt.Format(time.RFC3339)
		}
		result = append(result, info)
	}
	jsonResponse(w, result)
}

// DeleteUser deactivates a standard user. If permanent=true is supplied, it
// permanently deletes an already deactivated standard user and their data.
// DELETE /api/admin/users/{username}
func (ah *AdminHandler) DeleteUser(w http.ResponseWriter, r *http.Request) {
	username := r.PathValue("username")
	if username == "" {
		httpError(w, "username is required", http.StatusBadRequest)
		return
	}
	caller := auth.UsernameFromContext(r.Context())
	if username == caller {
		httpError(w, "cannot delete your own account", http.StatusForbidden)
		return
	}
	targetUser, ok := ah.users.Get(username)
	if !ok {
		httpError(w, fmt.Sprintf("user %q not found", username), http.StatusNotFound)
		return
	}
	if targetUser.Role == auth.RoleAdmin {
		httpError(w, "admin accounts cannot be deleted by another admin", http.StatusForbidden)
		return
	}
	permanent := r.URL.Query().Get("permanent") == "true"
	if !permanent {
		if targetUser.DeactivatedAt != nil {
			jsonResponse(w, map[string]string{"status": "already deactivated"})
			return
		}
		if err := ah.users.Deactivate(r.Context(), username); err != nil {
			httpError(w, err.Error(), http.StatusNotFound)
			return
		}
		jsonResponse(w, map[string]string{"status": "deactivated"})
		return
	}

	if targetUser.DeactivatedAt == nil {
		httpError(w, "user must be deactivated before permanent deletion", http.StatusConflict)
		return
	}
	if err := ah.deleteUserData(r.Context(), username); err != nil {
		slog.Error("failed to delete user data", "user", username, "error", err)
		httpError(w, "failed to delete user data", http.StatusInternalServerError)
		return
	}
	if err := ah.users.Delete(r.Context(), username); err != nil {
		httpError(w, err.Error(), http.StatusNotFound)
		return
	}
	jsonResponse(w, map[string]string{"status": "deleted"})
}

func (ah *AdminHandler) deleteUserData(ctx context.Context, username string) error {
	prefixes := []string{
		"files/" + username + "/",
		"thumbs/" + username + "/",
		"archive/" + username + "/",
		"archive-thumbs/" + username + "/",
	}
	for _, prefix := range prefixes {
		objects, err := ah.store.ListObjects(ctx, prefix)
		if err != nil {
			return fmt.Errorf("list %q: %w", prefix, err)
		}
		for _, obj := range objects {
			if err := ah.store.DeleteObject(ctx, obj.Key); err != nil {
				return fmt.Errorf("delete %q: %w", obj.Key, err)
			}
		}
	}
	if err := ah.store.DeleteObject(ctx, username+"/checksums.json"); err != nil && !storage.IsObjectNotFound(err) {
		return fmt.Errorf("delete checksum index: %w", err)
	}
	return nil
}

// ChangePassword changes a user's password. Admins can change standard users;
// every user can change their own password.
// PUT /api/admin/users/{username}/password
func (ah *AdminHandler) ChangePassword(w http.ResponseWriter, r *http.Request) {
	target := r.PathValue("username")
	if target == "" {
		httpError(w, "username is required", http.StatusBadRequest)
		return
	}

	caller := auth.UsernameFromContext(r.Context())
	callerRole := auth.RoleFromContext(r.Context())
	if caller != target {
		if callerRole != auth.RoleAdmin {
			httpError(w, "can only change your own password", http.StatusForbidden)
			return
		}
		targetUser, ok := ah.users.Get(target)
		if !ok {
			httpError(w, fmt.Sprintf("user %q not found", target), http.StatusNotFound)
			return
		}
		if targetUser.DeactivatedAt != nil {
			httpError(w, "deactivated user passwords cannot be changed", http.StatusConflict)
			return
		}
		if targetUser.Role == auth.RoleAdmin {
			httpError(w, "admin passwords can only be changed by the account owner", http.StatusForbidden)
			return
		}
	}
	var req ChangePasswordRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Password == "" {
		httpError(w, "password is required", http.StatusBadRequest)
		return
	}

	if err := ah.users.ChangePassword(r.Context(), target, req.Password); err != nil {
		httpError(w, err.Error(), http.StatusNotFound)
		return
	}

	jsonResponse(w, map[string]string{"status": "password changed"})
}

// --- Stats ---

// Stats returns storage analytics for the authenticated user.
// GET /api/stats
func (h *Handler) Stats(w http.ResponseWriter, r *http.Request) {
	username := auth.UsernameFromContext(r.Context())
	stats, err := h.store.ComputeUserStats(r.Context(), username)
	if err != nil {
		slog.Error("stats failed", "user", username, "error", err)
		httpError(w, "failed to compute stats", http.StatusInternalServerError)
		return
	}
	jsonResponse(w, stats)
}

// AdminStats returns aggregate storage analytics across all users.
// GET /api/admin/stats
func (ah *AdminHandler) AdminStats(w http.ResponseWriter, r *http.Request) {
	users := ah.users.List()

	type perUser struct {
		Username string `json:"username"`
		storage.UserStats
	}

	var allStats []perUser
	var totalSize int64
	var totalFiles int

	for username := range users {
		stats, err := ah.store.ComputeUserStats(r.Context(), username)
		if err != nil {
			slog.Error("admin stats failed", "user", username, "error", err)
			continue
		}
		allStats = append(allStats, perUser{Username: username, UserStats: stats})
		totalSize += stats.TotalSize
		totalFiles += stats.FileCount
	}

	jsonResponse(w, map[string]any{
		"users":       allStats,
		"total_size":  totalSize,
		"total_files": totalFiles,
	})
}

// --- Shared helpers ---

func (h *Handler) listObjectsWithPagination(w http.ResponseWriter, r *http.Request, prefix, filesSegment, thumbsSegment string) {
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if offset < 0 {
		offset = 0
	}

	objects, err := h.store.ListObjects(r.Context(), prefix)
	if err != nil {
		slog.Error("list objects failed", "prefix", prefix, "error", err)
		httpError(w, "failed to list files", http.StatusInternalServerError)
		return
	}

	totalCount := len(objects)

	end := offset + limit
	if offset > len(objects) {
		objects = nil
	} else {
		if end > len(objects) {
			end = len(objects)
		}
		objects = objects[offset:end]
	}

	files := make([]FileItem, 0, len(objects))
	for _, obj := range objects {
		ct := obj.ContentType
		if ct == "" {
			ct = mime.TypeByExtension(path.Ext(obj.Key))
		}
		if ct == "" {
			ct = "application/octet-stream"
		}
		item := FileItem{
			Key:          obj.Key,
			Size:         obj.Size,
			ContentType:  ct,
			LastModified: obj.LastModified,
		}
		if hasThumbnailSupport(ct) {
			item.ThumbnailKey = strings.Replace(obj.Key, filesSegment, thumbsSegment, 1)
		}
		if stat, err := h.store.StatObject(r.Context(), obj.Key); err == nil {
			item.Checksum = stat.UserMetadata["Checksum"]
			item.UploadDate = stat.UserMetadata["Upload-Date"]
			item.OriginalName = stat.UserMetadata["Original-Name"]
			if stat.ContentType != "" {
				item.ContentType = stat.ContentType
			}
		}
		files = append(files, item)
	}

	jsonResponse(w, FileListResponse{
		Files:      files,
		TotalCount: totalCount,
		Offset:     offset,
		Limit:      limit,
	})
}

// rekeyPrefix swaps the leading `from` segment of key with `to`.
// Returns "" if key does not start with `from`.
func rekeyPrefix(key, from, to string) string {
	if !strings.HasPrefix(key, from) {
		return ""
	}
	return to + strings.TrimPrefix(key, from)
}

// userOwnsKey checks that key lives in one of the active owner-prefixed
// namespaces for username.
func userOwnsKey(username, key string) bool {
	if username == "" {
		return false
	}
	prefixes := [...]string{
		"files/" + username + "/",
		"thumbs/" + username + "/",
	}
	for _, p := range prefixes {
		if strings.HasPrefix(key, p) {
			return true
		}
	}
	return false
}

// fileKeyToThumbKey converts "files/<user>/..." to "thumbs/<user>/...".
func fileKeyToThumbKey(key string) string {
	return rekeyPrefix(key, "files/", "thumbs/")
}

func sanitizeFilename(name string) string {
	return path.Base(name)
}

// sanitizePath cleans a relative path for safe storage.
// Prevents directory traversal and removes leading slashes.
func sanitizePath(p string) string {
	// Clean the path to resolve .. and .
	cleaned := path.Clean(p)
	// Remove leading slashes and dots
	cleaned = strings.TrimLeft(cleaned, "/.")
	if cleaned == "" {
		return "unnamed"
	}
	return cleaned
}

func jsonResponse(w http.ResponseWriter, data any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func httpError(w http.ResponseWriter, msg string, code int) {
	http.Error(w, msg, code)
}

func isImageContentType(ct string) bool {
	return strings.HasPrefix(ct, "image/")
}

func isVideoContentType(ct string) bool {
	return strings.HasPrefix(ct, "video/")
}

func isPDFContentType(ct string) bool {
	return ct == "application/pdf"
}

func hasThumbnailSupport(ct string) bool {
	return isImageContentType(ct) || isVideoContentType(ct) || isPDFContentType(ct)
}
