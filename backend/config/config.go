package config

import (
	"fmt"
	"os"
	"strings"
)

type Config struct {
	// Server
	Port string

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
}

func Load() (*Config, error) {
	minioPort := os.Getenv("MINIO_PORT")
	if minioPort == "" {
		return nil, fmt.Errorf("MINIO_PORT is not set; run: source load-infra-env")
	}

	cfg := &Config{
		Port:           envOr("PORT", "8080"),
		MinIOEndpoint:  envOr("MINIO_ENDPOINT", "127.0.0.1:"+minioPort),
		MinIOAccessKey: envOr("MINIO_ACCESS_KEY", "minioadmin"),
		MinIOSecretKey: envOr("MINIO_SECRET_KEY", "minioadmin"),
		MinIOBucket:    envOr("MINIO_BUCKET", "smartaffiliate"),
		MinIOUseSSL:    strings.ToLower(envOr("MINIO_USE_SSL", "false")) == "true",
		JWTSecret:      envOr("JWT_SECRET", "reliquary-dev-secret-change-me"),
		Username:       envOr("AUTH_USERNAME", "admin"),
		Password:       envOr("AUTH_PASSWORD", "admin"),
	}

	return cfg, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
