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
	"path"
	"strconv"
	"strings"
	"time"

	"reliquary-be/auth"
	"reliquary-be/config"
	"reliquary-be/storage"
	"reliquary-be/worker"
)

type Handler struct {
	store        *storage.Client
	thumbs       *worker.ThumbnailWorker
	archival     *worker.ArchivalWorker
	checksums    *storage.ChecksumIndex
	proxyBaseURL string
}

func New(cfg *config.Config, store *storage.Client, thumbs *worker.ThumbnailWorker, checksums *storage.ChecksumIndex, archival *worker.ArchivalWorker) *Handler {
	return &Handler{store: store, thumbs: thumbs, archival: archival, checksums: checksums, proxyBaseURL: cfg.ProxyBaseURL}
}

// --- Request / Response types ---

type UploadResponse struct {
	Key       string `json:"key"`
	Size      int64  `json:"size"`
	Duplicate bool   `json:"duplicate,omitempty"`
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
		jsonResponse(w, UploadResponse{Key: existingKey, Size: int64(len(data)), Duplicate: true})
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

	if hasThumbnailSupport(contentType) {
		h.thumbs.Submit(fileKey, contentType)
	}

	jsonResponse(w, UploadResponse{Key: fileKey, Size: header.Size})
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

	jsonResponse(w, map[string]string{"status": "deleted"})
}

// ListArchive returns archived files with pagination.
// GET /api/archive?offset=0&limit=50
func (h *Handler) ListArchive(w http.ResponseWriter, r *http.Request) {
	username := auth.UsernameFromContext(r.Context())
	h.listObjectsWithPagination(w, r, "archive/"+username+"/", "archive/", "archive-thumbs/")
}

// RestoreArchive moves a file from archive back to active files.
// POST /api/archive/restore?key=...
func (h *Handler) RestoreArchive(w http.ResponseWriter, r *http.Request) {
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

	restoredKey := rekeyPrefix(key, "archive/", "files/")
	if restoredKey == "" {
		httpError(w, "invalid archive key", http.StatusBadRequest)
		return
	}

	if err := h.store.MoveObject(r.Context(), key, restoredKey); err != nil {
		slog.Error("restore failed", "key", key, "error", err)
		httpError(w, "failed to restore file", http.StatusInternalServerError)
		return
	}

	thumbKey := rekeyPrefix(key, "archive/", "archive-thumbs/")
	restoredThumbKey := rekeyPrefix(key, "archive/", "thumbs/")
	if err := h.store.MoveObject(r.Context(), thumbKey, restoredThumbKey); err != nil {
		slog.Debug("no archived thumbnail to restore", "key", thumbKey)
	}

	if stat, err := h.store.StatObject(r.Context(), restoredKey); err == nil {
		if cs := stat.UserMetadata["Checksum"]; cs != "" {
			h.checksums.Add(r.Context(), username, cs, restoredKey)
		}
	}

	slog.Info("file restored from archive", "from", key, "to", restoredKey)
	jsonResponse(w, map[string]string{"status": "restored", "key": restoredKey})
}

// DeleteArchive removes an archived file.
// DELETE /api/archive?key=...
func (h *Handler) DeleteArchive(w http.ResponseWriter, r *http.Request) {
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
		slog.Error("delete archived object failed", "key", key, "error", err)
		httpError(w, "failed to delete archived file", http.StatusInternalServerError)
		return
	}

	h.checksums.RemoveByKey(r.Context(), username, key)

	thumbKey := rekeyPrefix(key, "archive/", "archive-thumbs/")
	if thumbKey != "" {
		h.store.DeleteObject(r.Context(), thumbKey)
	}

	jsonResponse(w, map[string]string{"status": "deleted"})
}

// RunArchival triggers the archival process manually.
// POST /api/archive/run
func (h *Handler) RunArchival(w http.ResponseWriter, r *http.Request) {
	go h.archival.RunOnce(context.Background())
	jsonResponse(w, map[string]string{"status": "archival started"})
}

// --- Admin handlers ---

type CreateUserRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Role     string `json:"role"`
}

type UserInfo struct {
	Username  string `json:"username"`
	Role      string `json:"role"`
	CreatedAt string `json:"created_at"`
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

	role := auth.RoleUser
	if req.Role == "admin" {
		role = auth.RoleAdmin
	}

	if err := ah.users.Create(r.Context(), req.Username, req.Password, role); err != nil {
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
		result = append(result, UserInfo{
			Username:  name,
			Role:      string(u.Role),
			CreatedAt: u.CreatedAt.Format(time.RFC3339),
		})
	}
	jsonResponse(w, result)
}

// DeleteUser deletes a user.
// DELETE /api/admin/users/{username}
func (ah *AdminHandler) DeleteUser(w http.ResponseWriter, r *http.Request) {
	username := r.PathValue("username")
	if username == "" {
		httpError(w, "username is required", http.StatusBadRequest)
		return
	}
	if err := ah.users.Delete(r.Context(), username); err != nil {
		httpError(w, err.Error(), http.StatusNotFound)
		return
	}
	jsonResponse(w, map[string]string{"status": "deleted"})
}

// ChangePassword changes a user's password. Admin can change any; users can change their own.
// PUT /api/admin/users/{username}/password
func (ah *AdminHandler) ChangePassword(w http.ResponseWriter, r *http.Request) {
	target := r.PathValue("username")
	if target == "" {
		httpError(w, "username is required", http.StatusBadRequest)
		return
	}

	caller := auth.UsernameFromContext(r.Context())
	callerRole := auth.RoleFromContext(r.Context())
	if callerRole != auth.RoleAdmin && caller != target {
		httpError(w, "can only change your own password", http.StatusForbidden)
		return
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

// userOwnsKey checks that key lives in one of the owner-prefixed namespaces
// for username (files/, archive/, thumbs/, archive-thumbs/).
func userOwnsKey(username, key string) bool {
	if username == "" {
		return false
	}
	prefixes := [...]string{
		"files/" + username + "/",
		"archive/" + username + "/",
		"thumbs/" + username + "/",
		"archive-thumbs/" + username + "/",
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
