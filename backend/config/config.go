package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	// Server
	ListenAddr string // "host:port" or unix socket path

	// Proxy
	ProxyBaseURL string // e.g. "http://localhost:2080"

	// MinIO
	MinIOEndpoint  string
	MinIOAccessKey string
	MinIOSecretKey string
	MinIOBucket    string
	MinIOUseSSL    bool

	// Auth
	JWTSecret string
	Username  string
	Password  string

	// Workers
	ThumbnailWorkers int

	// Lifecycle
	ArchiveAfterDays     int
	ArchiveCheckInterval time.Duration
}

func Load() (*Config, error) {
	minioPort := os.Getenv("MINIO_PORT")
	if minioPort == "" {
		return nil, fmt.Errorf("MINIO_PORT is not set; run: source load-infra-env")
	}

	listenAddr := envOr("LISTEN_ADDR", ":"+envOr("PORT", "8080"))

	cfg := &Config{
		ListenAddr:     listenAddr,
		ProxyBaseURL:   envOr("PROXY_BASE_URL", "http://localhost:2080"),
		MinIOEndpoint:  envOr("MINIO_ENDPOINT", "127.0.0.1:"+minioPort),
		MinIOAccessKey: envOr("MINIO_ACCESS_KEY", "minioadmin"),
		MinIOSecretKey: envOr("MINIO_SECRET_KEY", "minioadmin"),
		MinIOBucket:    envOr("MINIO_BUCKET", "reliquary"),
		MinIOUseSSL:    strings.ToLower(envOr("MINIO_USE_SSL", "false")) == "true",
		JWTSecret:      envOr("JWT_SECRET", "reliquary-dev-secret-change-me"),
		Username:       envOr("AUTH_USERNAME", "admin"),
		Password:       envOr("AUTH_PASSWORD", "admin"),

		ThumbnailWorkers:     envOrInt("THUMBNAIL_WORKERS", 4),

		ArchiveAfterDays:     envOrInt("ARCHIVE_AFTER_DAYS", 90),
		ArchiveCheckInterval: time.Duration(envOrInt("ARCHIVE_CHECK_HOURS", 24)) * time.Hour,
	}

	return cfg, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envOrInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}
