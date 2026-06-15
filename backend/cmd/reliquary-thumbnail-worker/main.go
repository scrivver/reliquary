package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"reliquary-be/config"
	"reliquary-be/storage"
	"reliquary-be/thumbnail"
	"reliquary-be/worker"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

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

	processor := worker.NewThumbnailProcessor(store)
	consumer, err := thumbnail.NewConsumer(
		cfg.RabbitMQURL,
		cfg.ThumbnailQueue,
		cfg.ThumbnailDeadQueue,
		cfg.ThumbnailPrefetch,
		cfg.ThumbnailConcurrency,
		cfg.ThumbnailMaxAttempts,
		processor,
	)
	if err != nil {
		slog.Error("initialize thumbnail consumer", "error", err)
		os.Exit(1)
	}
	defer consumer.Close()

	ctx, stop := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stop()

	slog.Info(
		"thumbnail worker started",
		"queue",
		cfg.ThumbnailQueue,
		"concurrency",
		cfg.ThumbnailConcurrency,
		"prefetch",
		cfg.ThumbnailPrefetch,
		"max_attempts",
		cfg.ThumbnailMaxAttempts,
	)
	if err := consumer.Run(ctx); err != nil {
		slog.Error("thumbnail consumer stopped", "error", err)
		os.Exit(1)
	}
	slog.Info("thumbnail worker stopped")
}
