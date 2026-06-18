package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"reliquary-be/auth"
	"reliquary-be/config"
	"reliquary-be/event"
	"reliquary-be/handler"
	"reliquary-be/storage"
	"reliquary-be/thumbnail"
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

	slog.Info(
		"auth mode",
		"mode", cfg.AuthMode,
		"password", cfg.PasswordAuthEnabled,
		"oidc", cfg.OIDCAuthEnabled,
		"proxy", cfg.ProxyAuthEnabled,
		"none", cfg.NoAuthEnabled,
	)

	// User store — only needed when password auth is enabled.
	var users *auth.UserStore
	if cfg.PasswordAuthEnabled {
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

	var events event.Emitter
	if cfg.EventsEnabled {
		events, err = event.NewRabbitMQEmitter(cfg.RabbitMQURL, cfg.EventQueue)
		if err != nil {
			slog.Error("failed to initialize file event publisher", "error", err)
			os.Exit(1)
		}
		slog.Info(
			"file event publisher ready",
			"queue",
			cfg.EventQueue,
			"device",
			cfg.EventDeviceName,
		)
	} else {
		slog.Warn("file event publication is disabled; Engram will not track mutations")
		events = event.DisabledEmitter{}
	}
	defer events.Close()

	thumbs, err := thumbnail.NewRabbitMQPublisher(cfg.RabbitMQURL, cfg.ThumbnailQueue)
	if err != nil {
		slog.Error("failed to initialize thumbnail job publisher", "error", err)
		os.Exit(1)
	}
	defer thumbs.Close()
	slog.Info("thumbnail job publisher ready", "queue", cfg.ThumbnailQueue)

	h := handler.New(cfg, store, thumbs, checksums, events)

	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	// Health check — retains auth_mode for older clients.
	r.Get("/api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"status":    "ok",
			"auth_mode": cfg.AuthMode,
		})
	})
	r.Get("/api/auth/config", authConfigHandler(cfg))
	if cfg.OIDCAuthEnabled {
		r.Get("/api/auth/oidc/discovery", oidcDiscoveryHandler(cfg))
		r.Post("/api/auth/oidc/token", oidcTokenHandler(cfg))
	}

	switch {
	case cfg.NoAuthEnabled:
		// No auth — single default user, all endpoints open.
		slog.Info("headless mode: no authentication, using default user", "user", cfg.Username)
		r.Group(func(r chi.Router) {
			r.Use(auth.NoAuthMiddleware(cfg.Username))
			registerFileRoutes(r, h)
		})

	case cfg.ProxyAuthEnabled && !cfg.PasswordAuthEnabled && !cfg.OIDCAuthEnabled:
		// Proxy mode — trust X-Reliquary-User header.
		slog.Info("proxy mode: trusting X-Reliquary-User header", "default_user", cfg.Username)
		r.Group(func(r chi.Router) {
			r.Use(auth.ProxyMiddleware(cfg.Username))
			registerFileRoutes(r, h)
		})

	default:
		var authSvc *auth.Service
		if cfg.PasswordAuthEnabled {
			authSvc = auth.NewService(cfg, users)
			r.Post("/api/login", authSvc.LoginHandler)
		}

		var oidcAuth *auth.OIDCAuthenticator
		if cfg.OIDCAuthEnabled {
			oidcAuth, err = auth.NewOIDCAuthenticator(context.Background(), cfg)
			if err != nil {
				slog.Error("failed to initialize OIDC authenticator", "error", err)
				os.Exit(1)
			}
		}
		if authSvc == nil && oidcAuth == nil {
			slog.Error("no usable auth providers enabled")
			os.Exit(1)
		}

		r.Group(func(r chi.Router) {
			r.Use(authProvidersMiddleware(authSvc, oidcAuth))
			registerFileRoutes(r, h)
		})

		if authSvc != nil {
			adminH := handler.NewAdminHandler(users, store)
			// Admin endpoints (admin role required).
			r.Group(func(r chi.Router) {
				r.Use(authSvc.Middleware)
				r.Use(authSvc.AdminMiddleware)

				r.Get("/api/admin/stats", adminH.AdminStats)
				r.Post("/api/admin/users", adminH.CreateUser)
				r.Get("/api/admin/users", adminH.ListUsers)
				r.Delete("/api/admin/users/{username}", adminH.DeleteUser)
				r.Put("/api/admin/users/{username}/activate", adminH.ActivateUser)
				r.Put("/api/admin/users/{username}/password", adminH.ChangePassword)
			})
		}
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

// registerFileRoutes registers the common file and stats routes.
func registerFileRoutes(r chi.Router, h *handler.Handler) {
	r.Post("/api/upload", h.Upload)
	r.Get("/api/files", h.ListFiles)
	r.Get("/api/files/presign", h.PresignDownload)
	r.Post("/api/files/download", h.BatchDownload)
	r.Delete("/api/files", h.DeleteFile)

	r.Get("/api/stats", h.Stats)
}

type authConfigResponse struct {
	Password authPasswordConfig `json:"password"`
	OIDC     authOIDCConfig     `json:"oidc"`
	Proxy    authProxyConfig    `json:"proxy"`
	None     authNoneConfig     `json:"none"`
}

type authPasswordConfig struct {
	Enabled bool `json:"enabled"`
}

type authOIDCConfig struct {
	Enabled       bool   `json:"enabled"`
	IssuerURL     string `json:"issuer_url,omitempty"`
	ClientID      string `json:"client_id,omitempty"`
	UsernameClaim string `json:"username_claim,omitempty"`
	RedirectURI   string `json:"redirect_uri,omitempty"`
}

type authProxyConfig struct {
	Enabled bool `json:"enabled"`
	Legacy  bool `json:"legacy"`
}

type authNoneConfig struct {
	Enabled bool `json:"enabled"`
}

type oidcDiscoveryResponse struct {
	Issuer                string `json:"issuer"`
	AuthorizationEndpoint string `json:"authorization_endpoint"`
	TokenEndpoint         string `json:"token_endpoint"`
	UserinfoEndpoint      string `json:"userinfo_endpoint"`
}

type oidcTokenRequest struct {
	GrantType    string `json:"grant_type"`
	Code         string `json:"code,omitempty"`
	RedirectURI  string `json:"redirect_uri,omitempty"`
	CodeVerifier string `json:"code_verifier,omitempty"`
	RefreshToken string `json:"refresh_token,omitempty"`
}

func authConfigHandler(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(authConfigResponse{
			Password: authPasswordConfig{Enabled: cfg.PasswordAuthEnabled},
			OIDC: authOIDCConfig{
				Enabled:       cfg.OIDCAuthEnabled,
				IssuerURL:     cfg.OIDCIssuerURL,
				ClientID:      cfg.OIDCClientID,
				UsernameClaim: cfg.OIDCUsernameClaim,
				RedirectURI:   cfg.OIDCRedirectURI,
			},
			Proxy: authProxyConfig{Enabled: cfg.ProxyAuthEnabled, Legacy: true},
			None:  authNoneConfig{Enabled: cfg.NoAuthEnabled},
		})
	}
}

func oidcDiscoveryHandler(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		discovery, err := fetchOIDCDiscovery(r.Context(), cfg.OIDCIssuerURL)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(discovery)
	}
}

func oidcTokenHandler(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req oidcTokenRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request body", http.StatusBadRequest)
			return
		}

		discovery, err := fetchOIDCDiscovery(r.Context(), cfg.OIDCIssuerURL)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}

		form := url.Values{}
		form.Set("grant_type", req.GrantType)
		form.Set("client_id", cfg.OIDCClientID)
		switch req.GrantType {
		case "authorization_code":
			if req.Code == "" || req.RedirectURI == "" || req.CodeVerifier == "" {
				http.Error(w, "code, redirect_uri, and code_verifier are required", http.StatusBadRequest)
				return
			}
			form.Set("code", req.Code)
			form.Set("redirect_uri", req.RedirectURI)
			form.Set("code_verifier", req.CodeVerifier)
		case "refresh_token":
			if req.RefreshToken == "" {
				http.Error(w, "refresh_token is required", http.StatusBadRequest)
				return
			}
			form.Set("refresh_token", req.RefreshToken)
		default:
			http.Error(w, "unsupported grant_type", http.StatusBadRequest)
			return
		}

		tokenReq, err := http.NewRequestWithContext(
			r.Context(),
			http.MethodPost,
			discovery.TokenEndpoint,
			strings.NewReader(form.Encode()),
		)
		if err != nil {
			http.Error(w, "failed to create token request", http.StatusInternalServerError)
			return
		}
		tokenReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")

		tokenResp, err := http.DefaultClient.Do(tokenReq)
		if err != nil {
			http.Error(w, fmt.Sprintf("token request failed: %v", err), http.StatusBadGateway)
			return
		}
		defer tokenResp.Body.Close()

		body, err := io.ReadAll(tokenResp.Body)
		if err != nil {
			http.Error(w, "failed to read token response", http.StatusBadGateway)
			return
		}
		if tokenResp.StatusCode != http.StatusOK {
			http.Error(w, string(body), tokenResp.StatusCode)
			return
		}

		var tokens map[string]any
		if err := json.Unmarshal(body, &tokens); err != nil {
			http.Error(w, "failed to parse token response", http.StatusBadGateway)
			return
		}

		if accessToken, ok := tokens["access_token"].(string); ok && accessToken != "" {
			username, err := fetchOIDCUsername(r.Context(), discovery.UserinfoEndpoint, accessToken, cfg.OIDCUsernameClaim)
			if err == nil {
				tokens["username"] = username
				tokens["role"] = string(auth.RoleUser)
			} else {
				slog.Warn("failed to resolve oidc username after token exchange", "error", err)
			}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(tokens)
	}
}

func fetchOIDCDiscovery(ctx context.Context, issuer string) (oidcDiscoveryResponse, error) {
	if issuer == "" {
		return oidcDiscoveryResponse{}, fmt.Errorf("OIDC_ISSUER_URL is not configured")
	}
	discoveryURL := strings.TrimRight(issuer, "/") + "/.well-known/openid-configuration"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, discoveryURL, nil)
	if err != nil {
		return oidcDiscoveryResponse{}, err
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return oidcDiscoveryResponse{}, fmt.Errorf("oidc discovery request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return oidcDiscoveryResponse{}, fmt.Errorf("oidc discovery returned %d: %s", resp.StatusCode, body)
	}

	var discovery oidcDiscoveryResponse
	if err := json.NewDecoder(resp.Body).Decode(&discovery); err != nil {
		return oidcDiscoveryResponse{}, fmt.Errorf("parse oidc discovery: %w", err)
	}
	return discovery, nil
}

func fetchOIDCUsername(ctx context.Context, userinfoEndpoint, accessToken, usernameClaim string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, userinfoEndpoint, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("userinfo request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("userinfo returned %d: %s", resp.StatusCode, body)
	}

	var claims map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&claims); err != nil {
		return "", err
	}
	username, ok := claims[usernameClaim].(string)
	if !ok || username == "" {
		return "", fmt.Errorf("userinfo missing claim %q", usernameClaim)
	}
	return username, nil
}

func authProvidersMiddleware(
	passwordAuth *auth.Service,
	oidcAuth *auth.OIDCAuthenticator,
) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if passwordAuth != nil {
				username, role, err := passwordAuth.AuthenticateRequest(r)
				if err == nil {
					ctx := auth.WithIdentity(r.Context(), username, role)
					next.ServeHTTP(w, r.WithContext(ctx))
					return
				}
			}

			if oidcAuth != nil {
				username, err := oidcAuth.AuthenticateRequest(r)
				if err == nil {
					ctx := auth.WithIdentity(r.Context(), username, auth.RoleUser)
					next.ServeHTTP(w, r.WithContext(ctx))
					return
				}
			}

			http.Error(w, "invalid token", http.StatusUnauthorized)
		})
	}
}
