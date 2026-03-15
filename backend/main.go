package main

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"reliquary-be/auth"
	"reliquary-be/config"
	"reliquary-be/handler"
	"reliquary-be/storage"
	"reliquary-be/worker"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	cfg, err := config.Load()
	if err != nil {
		slog.Error("failed to load config", "error", err)
		os.Exit(1)
	}

	store, err := storage.New(cfg)
	if err != nil {
		slog.Error("failed to connect to MinIO", "error", err)
		os.Exit(1)
	}
	slog.Info("connected to MinIO", "endpoint", cfg.MinIOEndpoint, "bucket", cfg.MinIOBucket)

	// User store.
	users := auth.NewUserStore(store)
	if err := users.Load(context.Background()); err != nil {
		slog.Error("failed to load user store", "error", err)
		os.Exit(1)
	}
	if err := users.Seed(context.Background(), cfg.Username, cfg.Password); err != nil {
		slog.Error("failed to seed admin user", "error", err)
		os.Exit(1)
	}

	// Migrate legacy single-user files to admin namespace.
	if err := storage.MigrateLegacyPrefix(context.Background(), store, cfg.Username); err != nil {
		slog.Error("failed to migrate legacy files", "error", err)
	}

	checksums := storage.NewChecksumIndex(store)

	authSvc := auth.NewService(cfg, users)
	thumbs := worker.NewThumbnailWorker(store)
	archival := worker.NewArchivalWorker(cfg, store, checksums, users)
	h := handler.New(cfg, store, thumbs, checksums, archival)
	adminH := handler.NewAdminHandler(users, store)

	// Start archival worker in background.
	go archival.Start(context.Background())

	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	// Public
	r.Post("/api/login", authSvc.LoginHandler)

	// Health check
	r.Get("/api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	// Protected
	r.Group(func(r chi.Router) {
		r.Use(authSvc.Middleware)

		r.Post("/api/upload", h.Upload)
		r.Get("/api/files", h.ListFiles)
		r.Get("/api/files/presign", h.PresignDownload)
		r.Delete("/api/files", h.DeleteFile)

		r.Get("/api/stats", h.Stats)

		r.Get("/api/archive", h.ListArchive)
		r.Post("/api/archive/restore", h.RestoreArchive)
		r.Post("/api/archive/run", h.RunArchival)
		r.Delete("/api/archive", h.DeleteArchive)

		// Admin endpoints (admin role required).
		r.Group(func(r chi.Router) {
			r.Use(authSvc.AdminMiddleware)

			r.Get("/api/admin/stats", adminH.AdminStats)
			r.Post("/api/admin/users", adminH.CreateUser)
			r.Get("/api/admin/users", adminH.ListUsers)
			r.Delete("/api/admin/users/{username}", adminH.DeleteUser)
			r.Put("/api/admin/users/{username}/password", adminH.ChangePassword)
		})
	})

	var ln net.Listener
	if strings.HasSuffix(cfg.ListenAddr, ".sock") || strings.HasPrefix(cfg.ListenAddr, "/") {
		os.Remove(cfg.ListenAddr)
		ln, err = net.Listen("unix", cfg.ListenAddr)
		if err != nil {
			slog.Error("failed to listen on unix socket", "path", cfg.ListenAddr, "error", err)
			os.Exit(1)
		}
		slog.Info("listening on unix socket", "path", cfg.ListenAddr)
	} else {
		ln, err = net.Listen("tcp", cfg.ListenAddr)
		if err != nil {
			slog.Error("failed to listen on TCP", "addr", cfg.ListenAddr, "error", err)
			os.Exit(1)
		}
		slog.Info("listening on TCP", "addr", cfg.ListenAddr)
	}

	if err := http.Serve(ln, r); err != nil {
		slog.Error("server error", "error", err)
		os.Exit(1)
	}
}
