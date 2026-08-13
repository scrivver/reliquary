package config

import (
	"fmt"
	"net/netip"
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
	AuthMode            string // "full" (JWT), "proxy" (trust header), "none" (single user), "oidc" (OIDC token validation)
	PasswordAuthEnabled bool
	OIDCAuthEnabled     bool
	ProxyAuthEnabled    bool
	NoAuthEnabled       bool
	JWTSecret           string
	Username            string
	Password            string

	// Proxy auth (AUTH_MODE=proxy)
	ProxySharedSecret        string // required secret the upstream proxy must present
	ProxyTrustHeaderInsecure bool   // opt out of the shared secret requirement

	// TrustedProxies are the peers whose X-Forwarded-For header is believed.
	// The login rate limiter keys on the client address, so a header trusted
	// from an arbitrary peer lets a caller mint a fresh quota per request.
	TrustedProxies []netip.Prefix

	// OIDC (AUTH_MODE=oidc)
	OIDCIssuerURL     string // e.g. "http://localhost:9000/application/o/mind-palace/"
	OIDCClientID      string // public client ID used for the PKCE code exchange
	OIDCUsernameClaim string // JWT claim for username (default: preferred_username)
	OIDCRedirectURI   string // native app redirect URI (default: com.reliquary.app://callback)

	// OIDCAudience is the aud claim an access token must carry to be accepted.
	// Defaults to OIDCClientID, which is what most providers stamp in. Without
	// it any token the issuer minted for any client would authenticate here.
	OIDCAudience string
	// OIDCAllowOpaqueTokens accepts non-JWT access tokens, which carry no claims
	// and therefore cannot be audience-checked.
	OIDCAllowOpaqueTokens bool

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

		ProxySharedSecret:        envOr("AUTH_PROXY_SHARED_SECRET", ""),
		ProxyTrustHeaderInsecure: envOrBool("AUTH_PROXY_INSECURE_TRUST_HEADER", false),

		OIDCIssuerURL:     envOr("OIDC_ISSUER_URL", ""),
		OIDCClientID:      envOr("OIDC_CLIENT_ID", ""),
		OIDCUsernameClaim: envOr("OIDC_USERNAME_CLAIM", "preferred_username"),
		OIDCRedirectURI:   envOr("OIDC_REDIRECT_URI", "com.reliquary.app://callback"),

		OIDCAudience:          envOr("OIDC_AUDIENCE", ""),
		OIDCAllowOpaqueTokens: envOrBool("OIDC_ALLOW_OPAQUE_TOKENS", false),

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

	// Most providers put the client ID in aud; OIDC_AUDIENCE only needs setting
	// when the provider uses something else (Keycloak, Authelia).
	if cfg.OIDCAudience == "" {
		cfg.OIDCAudience = cfg.OIDCClientID
	}

	trusted, err := parseTrustedProxies(os.LookupEnv("TRUSTED_PROXIES"))
	if err != nil {
		return nil, err
	}
	cfg.TrustedProxies = trusted

	cfg.PasswordAuthEnabled = defaultAuthProviderEnabled("AUTH_PASSWORD_ENABLED", cfg.AuthMode == "full")
	cfg.OIDCAuthEnabled = defaultAuthProviderEnabled("AUTH_OIDC_ENABLED", cfg.AuthMode == "oidc")
	cfg.ProxyAuthEnabled = defaultAuthProviderEnabled("AUTH_PROXY_ENABLED", cfg.AuthMode == "proxy")
	cfg.NoAuthEnabled = defaultAuthProviderEnabled("AUTH_NONE_ENABLED", cfg.AuthMode == "none")

	return cfg, nil
}

// defaultTrustedProxies covers the topologies Reliquary ships: the reverse
// proxy reaches the API over loopback or a container network, and the API port
// is not published. A peer outside these ranges is talking to the API directly,
// and nothing it claims about the client address is worth believing.
var defaultTrustedProxies = []string{
	"127.0.0.0/8",
	"::1/128",
	"10.0.0.0/8",
	"172.16.0.0/12",
	"192.168.0.0/16",
	"fc00::/7",
}

// parseTrustedProxies reads TRUSTED_PROXIES as a comma-separated list of CIDRs
// or bare addresses. An unset variable selects the defaults; an explicitly
// empty one trusts no peer, which is why this reads LookupEnv rather than
// Getenv. A malformed entry is a startup error: silently dropping it would
// leave the operator believing a proxy is trusted when it is not.
func parseTrustedProxies(raw string, set bool) ([]netip.Prefix, error) {
	entries := defaultTrustedProxies
	if set {
		entries = nil
		for _, e := range strings.Split(raw, ",") {
			if e = strings.TrimSpace(e); e != "" {
				entries = append(entries, e)
			}
		}
	}

	prefixes := make([]netip.Prefix, 0, len(entries))
	for _, e := range entries {
		if p, err := netip.ParsePrefix(e); err == nil {
			prefixes = append(prefixes, p.Masked())
			continue
		}
		addr, err := netip.ParseAddr(e)
		if err != nil {
			return nil, fmt.Errorf("TRUSTED_PROXIES: %q is not an IP address or CIDR range", e)
		}
		prefixes = append(prefixes, netip.PrefixFrom(addr, addr.BitLen()))
	}
	return prefixes, nil
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

func defaultAuthProviderEnabled(key string, fallback bool) bool {
	return envOrBool(key, fallback)
}
