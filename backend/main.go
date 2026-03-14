package main

import (
	"log/slog"
	"net/http"
	"os"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"

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

	authSvc := auth.NewService(cfg)
	thumbs := worker.NewThumbnailWorker(store)
	h := handler.New(store, thumbs)

	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   []string{"*"},
		AllowedMethods:   []string{"GET", "POST", "PUT", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Accept", "Authorization", "Content-Type"},
		ExposedHeaders:   []string{"Link"},
		AllowCredentials: true,
		MaxAge:           300,
	}))

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
	})

	slog.Info("starting server", "port", cfg.Port)
	if err := http.ListenAndServe(":"+cfg.Port, r); err != nil {
		slog.Error("server error", "error", err)
		os.Exit(1)
	}
}
