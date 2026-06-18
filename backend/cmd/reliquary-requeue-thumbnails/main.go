package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"mime"
	"os"
	"path"
	"strings"

	"reliquary-be/config"
	"reliquary-be/storage"
	"reliquary-be/thumbnail"
)

func main() {
	var (
		dryRun = flag.Bool("dry-run", false, "list matching files without publishing jobs")
		prefix = flag.String("prefix", "files/", "object key prefix to scan")
	)
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	ctx := context.Background()
	cfg, err := config.Load()
	if err != nil {
		slog.Error("load config", "error", err)
		os.Exit(1)
	}
	store, err := storage.New(cfg)
	if err != nil {
		slog.Error("connect to object storage", "error", err)
		os.Exit(1)
	}

	var publisher thumbnail.Publisher
	if !*dryRun {
		publisher, err = thumbnail.NewRabbitMQPublisher(cfg.RabbitMQURL, cfg.ThumbnailQueue)
		if err != nil {
			slog.Error("initialize thumbnail publisher", "error", err)
			os.Exit(1)
		}
		defer publisher.Close()
	}

	if err := requeuePDFThumbnails(ctx, store, publisher, *prefix, *dryRun); err != nil {
		slog.Error("requeue pdf thumbnails", "error", err)
		os.Exit(1)
	}
}

func requeuePDFThumbnails(
	ctx context.Context,
	store *storage.Client,
	publisher thumbnail.Publisher,
	prefix string,
	dryRun bool,
) error {
	objects, err := store.ListObjects(ctx, prefix)
	if err != nil {
		return fmt.Errorf("list objects: %w", err)
	}

	var matched, published, skipped int
	for _, obj := range objects {
		contentType := obj.ContentType
		if contentType == "" {
			contentType = mime.TypeByExtension(path.Ext(obj.Key))
		}
		if !isPDF(obj.Key, contentType) {
			continue
		}
		matched++

		stat, err := store.StatObject(ctx, obj.Key)
		if err != nil {
			return fmt.Errorf("stat %q: %w", obj.Key, err)
		}
		checksum := metadataValue(stat.UserMetadata, "Checksum")
		if checksum == "" {
			slog.Warn("skipping pdf without checksum metadata", "key", obj.Key)
			skipped++
			continue
		}

		job := thumbnail.Job{
			Version:     thumbnail.JobVersion,
			FileKey:     obj.Key,
			ContentType: "application/pdf",
			Checksum:    checksum,
		}
		if dryRun {
			slog.Info("would publish thumbnail job", "key", obj.Key)
			continue
		}
		if err := publisher.Publish(ctx, job); err != nil {
			return fmt.Errorf("publish thumbnail job for %q: %w", obj.Key, err)
		}
		published++
		slog.Info("published thumbnail job", "key", obj.Key)
	}

	slog.Info(
		"pdf thumbnail requeue complete",
		"matched",
		matched,
		"published",
		published,
		"skipped",
		skipped,
		"dry_run",
		dryRun,
	)
	return nil
}

func isPDF(key, contentType string) bool {
	return contentType == "application/pdf" ||
		strings.EqualFold(path.Ext(key), ".pdf")
}

func metadataValue(metadata map[string]string, key string) string {
	for metadataKey, value := range metadata {
		if strings.EqualFold(metadataKey, key) {
			return value
		}
	}
	return ""
}
