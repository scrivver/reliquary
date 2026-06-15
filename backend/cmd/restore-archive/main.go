package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"

	"reliquary-be/config"
	"reliquary-be/storage"
)

func main() {
	apply := flag.Bool("apply", false, "move archived objects; default is dry-run")
	flag.Parse()

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

	report, err := storage.RestoreArchivedObjects(
		context.Background(),
		store,
		*apply,
	)
	if err != nil {
		slog.Error("restore archived objects", "error", err)
		os.Exit(1)
	}
	if *apply && report.Failed == 0 {
		if err := storage.RebuildChecksumIndexes(context.Background(), store); err != nil {
			slog.Error("rebuild checksum indexes", "error", err)
			os.Exit(1)
		}
	}

	mode := "dry-run"
	if *apply {
		mode = "apply"
	}
	fmt.Printf(
		"mode=%s planned=%d restored=%d conflicts=%d failed=%d\n",
		mode,
		report.Planned,
		report.Restored,
		report.Conflicts,
		report.Failed,
	)
	for _, conflict := range report.ConflictKeys {
		fmt.Printf("conflict: %s\n", conflict)
	}
	for _, failed := range report.FailedKeys {
		fmt.Printf("failed: %s\n", failed)
	}
	if report.Conflicts > 0 || report.Failed > 0 {
		os.Exit(2)
	}
}
