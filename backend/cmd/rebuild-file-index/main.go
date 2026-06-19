package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"

	"reliquary-be/auth"
	"reliquary-be/config"
	"reliquary-be/storage"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	username := flag.String("username", "", "rebuild the file index for one user")
	all := flag.Bool("all", false, "rebuild file indexes for all local users")
	flag.Parse()

	if (*username == "" && !*all) || (*username != "" && *all) {
		fmt.Fprintln(os.Stderr, "usage: rebuild-file-index --username USER | --all")
		os.Exit(2)
	}

	cfg, err := config.Load()
	if err != nil {
		slog.Error("failed to load config", "error", err)
		os.Exit(1)
	}

	store, err := storage.New(cfg)
	if err != nil {
		slog.Error("failed to connect to object storage", "error", err)
		os.Exit(1)
	}

	ctx := context.Background()
	index := storage.NewFileIndex(store)

	users := []string{*username}
	if *all {
		users = []string{cfg.Username}
		if cfg.PasswordAuthEnabled {
			userStore := auth.NewUserStore(store)
			if err := userStore.Load(ctx); err != nil {
				slog.Error("failed to load user store", "error", err)
				os.Exit(1)
			}
			users = users[:0]
			for name := range userStore.List() {
				users = append(users, name)
			}
		}
	}

	for _, user := range users {
		manifest, err := index.Rebuild(ctx, user)
		if err != nil {
			slog.Error("failed to rebuild file index", "user", user, "error", err)
			os.Exit(1)
		}
		fmt.Printf("rebuilt file index for %s: %d files\n", user, len(manifest.Files))
	}
}
