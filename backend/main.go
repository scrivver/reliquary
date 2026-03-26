package main

import (
	"context"
	"encoding/json"
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

	slog.Info("auth mode", "mode", cfg.AuthMode)

	// User store — only needed for full auth mode.
	var users *auth.UserStore
	if cfg.AuthMode == "full" {
		users = auth.NewUserStore(store)
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
	}

	checksums := storage.NewChecksumIndex(store)

	thumbs := worker.NewThumbnailWorker(store, cfg.ThumbnailWorkers)
	thumbs.Start(context.Background(), cfg.ThumbnailWorkers)

	archival := worker.NewArchivalWorker(cfg, store, checksums, users)
	h := handler.New(cfg, store, thumbs, checksums, archival)

	// Start archival worker in background.
	go archival.Start(context.Background())

	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	// Health check — returns auth mode so clients can adapt.
	r.Get("/api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"status":    "ok",
			"auth_mode": cfg.AuthMode,
		})
	})

	switch cfg.AuthMode {
	case "none":
		// No auth — single default user, all endpoints open.
		slog.Info("headless mode: no authentication, using default user", "user", cfg.Username)
		r.Group(func(r chi.Router) {
			r.Use(auth.NoAuthMiddleware(cfg.Username))
			registerFileRoutes(r, h)
		})

	case "proxy":
		// Proxy mode — trust X-Reliquary-User header.
		slog.Info("proxy mode: trusting X-Reliquary-User header", "default_user", cfg.Username)
		r.Group(func(r chi.Router) {
			r.Use(auth.ProxyMiddleware(cfg.Username))
			registerFileRoutes(r, h)
		})

	default: // "full"
		// Full JWT auth mode.
		authSvc := auth.NewService(cfg, users)
		adminH := handler.NewAdminHandler(users, store)

		r.Post("/api/login", authSvc.LoginHandler)

		r.Group(func(r chi.Router) {
			r.Use(authSvc.Middleware)
			registerFileRoutes(r, h)

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
	}

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

// registerFileRoutes registers the common file/archive/stats routes.
func registerFileRoutes(r chi.Router, h *handler.Handler) {
	r.Post("/api/upload", h.Upload)
	r.Get("/api/files", h.ListFiles)
	r.Get("/api/files/presign", h.PresignDownload)
	r.Post("/api/files/download", h.BatchDownload)
	r.Delete("/api/files", h.DeleteFile)

	r.Get("/api/stats", h.Stats)

	r.Get("/api/archive", h.ListArchive)
	r.Post("/api/archive/restore", h.RestoreArchive)
	r.Post("/api/archive/run", h.RunArchival)
	r.Delete("/api/archive", h.DeleteArchive)
}
