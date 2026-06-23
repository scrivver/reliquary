package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"reliquary-be/config"
)

type contextKey string

const (
	ctxUsername contextKey = "username"
	ctxRole     contextKey = "role"
)

type Service struct {
	secret      []byte
	users       *UserStore
	rateLimiter *RateLimiter
}

type Source string

const (
	SourcePassword Source = "password"
	SourceOIDC     Source = "oidc"
)

type Claims struct {
	Username string `json:"username"`
	Role     Role   `json:"role"`
	Source   Source `json:"source"`
	jwt.RegisteredClaims
}

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type LoginResponse struct {
	Token    string `json:"token"`
	Username string `json:"username"`
	Role     string `json:"role"`
}

func NewService(cfg *config.Config, users *UserStore) *Service {
	return &Service{
		secret:      []byte(cfg.JWTSecret),
		users:       users,
		rateLimiter: NewRateLimiter(),
	}
}

func (s *Service) LoginHandler(w http.ResponseWriter, r *http.Request) {
	ip := ExtractIP(r)
	if !s.rateLimiter.Allow(ip) {
		http.Error(w, "too many login attempts, try again later", http.StatusTooManyRequests)
		return
	}

	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	user, err := s.users.Authenticate(req.Username, req.Password)
	if err != nil {
		http.Error(w, "invalid credentials", http.StatusUnauthorized)
		return
	}

	// Reset rate limit on successful login.
	s.rateLimiter.Reset(ip)

	claims := &Claims{
		Username: req.Username,
		Role:     user.Role,
		Source:   SourcePassword,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(72 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}

	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(s.secret)
	if err != nil {
		http.Error(w, "failed to create token", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(LoginResponse{
		Token:    token,
		Username: req.Username,
		Role:     string(user.Role),
	})
}

// Middleware validates the JWT and injects username/role into the request context.
func (s *Service) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		username, role, err := s.AuthenticateRequest(r)
		if err != nil {
			http.Error(w, err.Error(), http.StatusUnauthorized)
			return
		}

		ctx := context.WithValue(r.Context(), ctxUsername, username)
		ctx = context.WithValue(ctx, ctxRole, role)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (s *Service) AuthenticateRequest(r *http.Request) (string, Role, error) {
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		return "", "", fmt.Errorf("missing authorization header")
	}

	tokenStr := strings.TrimPrefix(authHeader, "Bearer ")
	if tokenStr == authHeader {
		return "", "", fmt.Errorf("invalid authorization format")
	}

	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (any, error) {
		return s.secret, nil
	})
	if err != nil || !token.Valid {
		return "", "", fmt.Errorf("invalid token")
	}

	return claims.Username, claims.Role, nil
}

// AdminMiddleware rejects non-admin users.
func (s *Service) AdminMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		role := RoleFromContext(r.Context())
		if role != RoleAdmin {
			http.Error(w, "admin access required", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// UsernameFromContext returns the authenticated username.
func UsernameFromContext(ctx context.Context) string {
	v, _ := ctx.Value(ctxUsername).(string)
	return v
}

// RoleFromContext returns the authenticated user's role.
func RoleFromContext(ctx context.Context) Role {
	v, _ := ctx.Value(ctxRole).(Role)
	return v
}

func WithIdentity(ctx context.Context, username string, role Role) context.Context {
	ctx = context.WithValue(ctx, ctxUsername, username)
	return context.WithValue(ctx, ctxRole, role)
}
