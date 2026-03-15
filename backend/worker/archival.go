package worker

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"reliquary-be/config"
	"reliquary-be/storage"
)

type ArchivalWorker struct {
	store     *storage.Client
	checksums *storage.ChecksumIndex
	cfg       *config.Config
}

func NewArchivalWorker(cfg *config.Config, store *storage.Client, checksums *storage.ChecksumIndex) *ArchivalWorker {
	return &ArchivalWorker{store: store, checksums: checksums, cfg: cfg}
}

// Start runs the archival check on the configured interval.
func (w *ArchivalWorker) Start(ctx context.Context) {
	slog.Info("archival worker started",
		"archive_after_days", w.cfg.ArchiveAfterDays,
		"check_interval", w.cfg.ArchiveCheckInterval,
	)

	// Run once immediately on startup.
	w.RunOnce(ctx)

	ticker := time.NewTicker(w.cfg.ArchiveCheckInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			slog.Info("archival worker stopped")
			return
		case <-ticker.C:
			w.RunOnce(ctx)
		}
	}
}

// RunOnce scans user/files/ and archives files older than the threshold.
func (w *ArchivalWorker) RunOnce(ctx context.Context) {
	cutoff := time.Now().Add(-time.Duration(w.cfg.ArchiveAfterDays) * 24 * time.Hour)
	slog.Info("archival scan starting", "cutoff", cutoff.Format(time.RFC3339))

	objects, err := w.store.ListObjects(ctx, "user/files/")
	if err != nil {
		slog.Error("archival: failed to list objects", "error", err)
		return
	}

	archived := 0
	for _, obj := range objects {
		if obj.LastModified.After(cutoff) {
			continue
		}

		archiveKey := strings.Replace(obj.Key, "/files/", "/archive/", 1)

		if err := w.store.MoveObject(ctx, obj.Key, archiveKey); err != nil {
			slog.Error("archival: failed to move object", "key", obj.Key, "error", err)
			continue
		}

		// Move the thumbnail too if it exists.
		thumbKey := strings.Replace(obj.Key, "/files/", "/thumbs/", 1)
		archiveThumbKey := strings.Replace(obj.Key, "/files/", "/archive-thumbs/", 1)
		if err := w.store.MoveObject(ctx, thumbKey, archiveThumbKey); err != nil {
			// Thumbnail may not exist; that's fine.
			slog.Debug("archival: no thumbnail to move", "key", thumbKey)
		}

		// Update checksum index with new key.
		if stat, err := w.store.StatObject(ctx, archiveKey); err == nil {
			checksum := stat.UserMetadata["Checksum"]
			if checksum != "" {
				if err := w.checksums.Add(ctx, checksum, archiveKey); err != nil {
					slog.Error("archival: failed to update checksum index", "error", err)
				}
			}
		}

		archived++
		slog.Info("archived file", "from", obj.Key, "to", archiveKey)
	}

	slog.Info("archival scan complete", "archived", archived, "total_scanned", len(objects))
}
