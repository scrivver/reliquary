package worker

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"reliquary-be/auth"
	"reliquary-be/config"
	"reliquary-be/storage"
)

type ArchivalWorker struct {
	store     *storage.Client
	checksums *storage.ChecksumIndex
	users     *auth.UserStore
	cfg       *config.Config
}

func NewArchivalWorker(cfg *config.Config, store *storage.Client, checksums *storage.ChecksumIndex, users *auth.UserStore) *ArchivalWorker {
	return &ArchivalWorker{store: store, checksums: checksums, users: users, cfg: cfg}
}

// Start runs the archival check on the configured interval.
func (w *ArchivalWorker) Start(ctx context.Context) {
	slog.Info("archival worker started",
		"archive_after_days", w.cfg.ArchiveAfterDays,
		"check_interval", w.cfg.ArchiveCheckInterval,
	)

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

// RunOnce scans all users' files and archives those older than the threshold.
func (w *ArchivalWorker) RunOnce(ctx context.Context) {
	cutoff := time.Now().Add(-time.Duration(w.cfg.ArchiveAfterDays) * 24 * time.Hour)
	slog.Info("archival scan starting", "cutoff", cutoff.Format(time.RFC3339))

	var usernames []string
	if w.users != nil {
		for name := range w.users.List() {
			usernames = append(usernames, name)
		}
	} else {
		// Headless mode — use default user from config.
		usernames = []string{w.cfg.Username}
	}

	totalArchived := 0
	for _, username := range usernames {
		archived := w.archiveUserFiles(ctx, username, cutoff)
		totalArchived += archived
	}

	slog.Info("archival scan complete", "total_archived", totalArchived)
}

func (w *ArchivalWorker) archiveUserFiles(ctx context.Context, username string, cutoff time.Time) int {
	prefix := "files/" + username + "/"
	objects, err := w.store.ListObjects(ctx, prefix)
	if err != nil {
		slog.Error("archival: failed to list objects", "user", username, "error", err)
		return 0
	}

	archived := 0
	for _, obj := range objects {
		if obj.LastModified.After(cutoff) {
			continue
		}

		archiveKey := "archive/" + strings.TrimPrefix(obj.Key, "files/")

		if err := w.store.MoveObject(ctx, obj.Key, archiveKey); err != nil {
			slog.Error("archival: failed to move object", "key", obj.Key, "error", err)
			continue
		}

		thumbKey := "thumbs/" + strings.TrimPrefix(obj.Key, "files/")
		archiveThumbKey := "archive-thumbs/" + strings.TrimPrefix(obj.Key, "files/")
		if err := w.store.MoveObject(ctx, thumbKey, archiveThumbKey); err != nil {
			slog.Debug("archival: no thumbnail to move", "key", thumbKey)
		}

		if stat, err := w.store.StatObject(ctx, archiveKey); err == nil {
			if cs := stat.UserMetadata["Checksum"]; cs != "" {
				w.checksums.Add(ctx, username, cs, archiveKey)
			}
		}

		archived++
		slog.Info("archived file", "user", username, "from", obj.Key, "to", archiveKey)
	}

	return archived
}
