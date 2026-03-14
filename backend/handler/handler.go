package handler

import (
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

	"reliquary-be/config"
	"reliquary-be/storage"
	"reliquary-be/worker"
)

type Handler struct {
	store        *storage.Client
	thumbs       *worker.ThumbnailWorker
	proxyBaseURL string
}

func New(cfg *config.Config, store *storage.Client, thumbs *worker.ThumbnailWorker) *Handler {
	return &Handler{store: store, thumbs: thumbs, proxyBaseURL: cfg.ProxyBaseURL}
}

// --- Request / Response types ---

type UploadResponse struct {
	Key  string `json:"key"`
	Size int64  `json:"size"`
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

// --- Handlers ---

// Upload handles multipart file upload, stores the file in MinIO, and
// triggers thumbnail generation.
// POST /api/upload
func (h *Handler) Upload(w http.ResponseWriter, r *http.Request) {
	// 32 MB max memory for multipart parsing; rest spills to disk.
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

	now := time.Now()
	baseName := strings.TrimSuffix(filename, path.Ext(filename))
	ext := path.Ext(filename)
	fileKey := fmt.Sprintf("user/files/%d/%02d/%s", now.Year(), now.Month(), filename)

	// Avoid overwriting existing files by appending a suffix.
	for i := 1; ; i++ {
		_, err := h.store.StatObject(r.Context(), fileKey)
		if err != nil {
			break // Object doesn't exist, safe to use this key.
		}
		fileKey = fmt.Sprintf("user/files/%d/%02d/%s_%d%s", now.Year(), now.Month(), baseName, i, ext)
	}

	// Read file into memory to compute checksum before uploading.
	data, err := io.ReadAll(file)
	if err != nil {
		httpError(w, "failed to read file", http.StatusInternalServerError)
		return
	}

	hash := sha256.Sum256(data)
	checksum := hex.EncodeToString(hash[:])

	meta := map[string]string{
		"Checksum":     checksum,
		"Upload-Date":  now.UTC().Format(time.RFC3339),
		"Original-Name": header.Filename,
	}

	if err := h.store.PutObject(r.Context(), fileKey, bytes.NewReader(data), int64(len(data)), contentType, meta); err != nil {
		slog.Error("upload to minio failed", "key", fileKey, "error", err)
		httpError(w, "failed to store file", http.StatusInternalServerError)
		return
	}

	slog.Info("file uploaded", "key", fileKey, "size", len(data), "checksum", checksum)

	// Generate thumbnail in the background (images and videos).
	if isImageContentType(contentType) || isVideoContentType(contentType) {
		go func() {
			if err := h.thumbs.GenerateThumbnail(context.Background(), fileKey, contentType); err != nil {
				slog.Error("thumbnail generation failed", "key", fileKey, "error", err)
			}
		}()
	}

	jsonResponse(w, UploadResponse{Key: fileKey, Size: header.Size})
}

// ListFiles returns files with pagination support.
// GET /api/files?offset=0&limit=50
func (h *Handler) ListFiles(w http.ResponseWriter, r *http.Request) {
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if offset < 0 {
		offset = 0
	}

	objects, err := h.store.ListObjects(r.Context(), "user/files/")
	if err != nil {
		slog.Error("list objects failed", "error", err)
		httpError(w, "failed to list files", http.StatusInternalServerError)
		return
	}

	totalCount := len(objects)

	// Apply pagination.
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
		if isImageContentType(ct) || isVideoContentType(ct) {
			item.ThumbnailKey = strings.Replace(obj.Key, "/files/", "/thumbs/", 1)
		}

		// Fetch user metadata (checksum, upload date, original name).
		if stat, err := h.store.StatObject(r.Context(), obj.Key); err == nil {
			item.Checksum = stat.UserMetadata["Checksum"]
			item.UploadDate = stat.UserMetadata["Upload-Date"]
			item.OriginalName = stat.UserMetadata["Original-Name"]
			// Use stat's content type if available (more reliable).
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

// PresignDownload generates a presigned GET URL routed through the reverse proxy.
// GET /api/files/presign?key=...
func (h *Handler) PresignDownload(w http.ResponseWriter, r *http.Request) {
	key := r.URL.Query().Get("key")
	if key == "" {
		httpError(w, "key query parameter is required", http.StatusBadRequest)
		return
	}

	presignedURL, err := h.store.PresignGet(r.Context(), key)
	if err != nil {
		slog.Error("presign get failed", "key", key, "error", err)
		httpError(w, "failed to generate download URL", http.StatusInternalServerError)
		return
	}

	// Rewrite the MinIO URL to go through the reverse proxy at /storage/.
	proxyURL := h.proxyBaseURL + "/storage" + presignedURL.Path
	if presignedURL.RawQuery != "" {
		proxyURL += "?" + presignedURL.RawQuery
	}

	jsonResponse(w, PresignDownloadResponse{URL: proxyURL})
}

// DeleteFile removes a file and its thumbnail from MinIO.
// DELETE /api/files?key=...
func (h *Handler) DeleteFile(w http.ResponseWriter, r *http.Request) {
	key := r.URL.Query().Get("key")
	if key == "" {
		httpError(w, "key query parameter is required", http.StatusBadRequest)
		return
	}

	if err := h.store.DeleteObject(r.Context(), key); err != nil {
		slog.Error("delete object failed", "key", key, "error", err)
		httpError(w, "failed to delete file", http.StatusInternalServerError)
		return
	}

	// Also delete the thumbnail if one might exist.
	thumbKey := strings.Replace(key, "/files/", "/thumbs/", 1)
	if thumbKey != key {
		if err := h.store.DeleteObject(r.Context(), thumbKey); err != nil {
			slog.Warn("delete thumbnail failed (may not exist)", "key", thumbKey, "error", err)
		}
	}

	jsonResponse(w, map[string]string{"status": "deleted"})
}

// --- Helpers ---

func sanitizeFilename(name string) string {
	return path.Base(name)
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
