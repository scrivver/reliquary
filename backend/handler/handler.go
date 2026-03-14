package handler

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"path"
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
	PhotoKey string `json:"photo_key"`
	Size     int64  `json:"size"`
}

type FileItem struct {
	Key          string    `json:"key"`
	Size         int64     `json:"size"`
	LastModified time.Time `json:"last_modified"`
	ThumbnailKey string    `json:"thumbnail_key"`
}

type FileListResponse struct {
	Files []FileItem `json:"files"`
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
	photoKey := fmt.Sprintf("user/photos/%d/%02d/%s", now.Year(), now.Month(), filename)

	if err := h.store.PutObject(r.Context(), photoKey, file, header.Size, contentType); err != nil {
		slog.Error("upload to minio failed", "key", photoKey, "error", err)
		httpError(w, "failed to store file", http.StatusInternalServerError)
		return
	}

	slog.Info("file uploaded", "key", photoKey, "size", header.Size)

	// Generate thumbnail in the background.
	go func() {
		if err := h.thumbs.GenerateThumbnail(context.Background(), photoKey); err != nil {
			slog.Error("thumbnail generation failed", "key", photoKey, "error", err)
		}
	}()

	jsonResponse(w, UploadResponse{PhotoKey: photoKey, Size: header.Size})
}

// ListFiles returns all photos with their thumbnail keys.
// GET /api/files
func (h *Handler) ListFiles(w http.ResponseWriter, r *http.Request) {
	objects, err := h.store.ListObjects(r.Context(), "user/photos/")
	if err != nil {
		slog.Error("list objects failed", "error", err)
		httpError(w, "failed to list files", http.StatusInternalServerError)
		return
	}

	files := make([]FileItem, 0, len(objects))
	for _, obj := range objects {
		thumbKey := strings.Replace(obj.Key, "/photos/", "/thumbs/", 1)
		files = append(files, FileItem{
			Key:          obj.Key,
			Size:         obj.Size,
			LastModified: obj.LastModified,
			ThumbnailKey: thumbKey,
		})
	}

	jsonResponse(w, FileListResponse{Files: files})
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

	// Also delete the thumbnail.
	thumbKey := strings.Replace(key, "/photos/", "/thumbs/", 1)
	if err := h.store.DeleteObject(r.Context(), thumbKey); err != nil {
		slog.Warn("delete thumbnail failed (may not exist)", "key", thumbKey, "error", err)
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
