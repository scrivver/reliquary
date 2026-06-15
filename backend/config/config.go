package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
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
	AuthMode  string // "full" (JWT), "proxy" (trust header), "none" (single user), "oidc" (OIDC token validation)
	JWTSecret string
	Username  string
	Password  string

	// OIDC (AUTH_MODE=oidc)
	OIDCIssuerURL     string // e.g. "http://localhost:9000/application/o/mind-palace/"
	OIDCClientID      string // expected aud claim
	OIDCUsernameClaim string // JWT claim for username (default: preferred_username)

	// File events
	EventsEnabled   bool
	RabbitMQURL     string
	EventQueue      string
	EventDeviceName string

	// Thumbnail jobs
	ThumbnailQueue       string
	ThumbnailDeadQueue   string
	ThumbnailPrefetch    int
	ThumbnailConcurrency int
	ThumbnailMaxAttempts int
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
		MinIOAccessKey: envOr("MINIO_ACCESS_KEY", envOr("MINIO_ROOT_USER", "minioadmin")),
		MinIOSecretKey: envOr("MINIO_SECRET_KEY", envOr("MINIO_ROOT_PASSWORD", "minioadmin")),
		MinIOBucket:    envOr("MINIO_BUCKET", "reliquary"),
		MinIOUseSSL:    strings.ToLower(envOr("MINIO_USE_SSL", "false")) == "true",
		AuthMode:       strings.ToLower(envOr("AUTH_MODE", "full")),
		JWTSecret:      envOr("JWT_SECRET", "reliquary-dev-secret-change-me"),
		Username:       envOr("AUTH_USERNAME", "admin"),
		Password:       envOr("AUTH_PASSWORD", "admin"),

		OIDCIssuerURL:     envOr("OIDC_ISSUER_URL", ""),
		OIDCClientID:      envOr("OIDC_CLIENT_ID", ""),
		OIDCUsernameClaim: envOr("OIDC_USERNAME_CLAIM", "preferred_username"),

		EventsEnabled:   envOrBool("EVENTS_ENABLED", true),
		RabbitMQURL:     envOr("RABBITMQ_URL", "amqp://guest:guest@127.0.0.1:5672"),
		EventQueue:      envOr("EVENT_QUEUE", "engram.ingest"),
		EventDeviceName: envOr("EVENT_DEVICE_NAME", "reliquary"),

		ThumbnailQueue:       envOr("THUMBNAIL_QUEUE", "reliquary.thumbnail"),
		ThumbnailDeadQueue:   envOr("THUMBNAIL_DEAD_QUEUE", "reliquary.thumbnail.dead"),
		ThumbnailPrefetch:    envOrInt("THUMBNAIL_PREFETCH", 1),
		ThumbnailConcurrency: envOrInt("THUMBNAIL_CONCURRENCY", 4),
		ThumbnailMaxAttempts: envOrInt("THUMBNAIL_MAX_ATTEMPTS", 5),
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

func envOrBool(key string, fallback bool) bool {
	if v := os.Getenv(key); v != "" {
		if parsed, err := strconv.ParseBool(v); err == nil {
			return parsed
		}
	}
	return fallback
}
