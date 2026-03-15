package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"

	"reliquary-be/storage"
)

const usersKey = "admin/users.json"

type Role string

const (
	RoleAdmin Role = "admin"
	RoleUser  Role = "user"
)

type User struct {
	PasswordHash string    `json:"password_hash"`
	Role         Role      `json:"role"`
	CreatedAt    time.Time `json:"created_at"`
}

type UserStore struct {
	client *storage.Client
	mu     sync.RWMutex
	users  map[string]User // username → User
}

func NewUserStore(client *storage.Client) *UserStore {
	return &UserStore{
		client: client,
		users:  make(map[string]User),
	}
}

// Load reads the user store from MinIO.
func (s *UserStore) Load(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	obj, err := s.client.GetObject(ctx, usersKey)
	if err != nil {
		slog.Info("user store not found, starting empty")
		return nil
	}
	defer obj.Close()

	data, err := io.ReadAll(obj)
	if err != nil || len(data) == 0 {
		return nil
	}

	if err := json.Unmarshal(data, &s.users); err != nil {
		slog.Warn("failed to parse user store, starting empty", "error", err)
		s.users = make(map[string]User)
	}

	slog.Info("user store loaded", "users", len(s.users))
	return nil
}

// Seed creates the initial admin user if no users exist.
func (s *UserStore) Seed(ctx context.Context, username, password string) error {
	s.mu.RLock()
	count := len(s.users)
	s.mu.RUnlock()

	if count > 0 {
		return nil
	}

	slog.Info("seeding initial admin user", "username", username)
	return s.Create(ctx, username, password, RoleAdmin)
}

// Create adds a new user.
func (s *UserStore) Create(ctx context.Context, username, password string, role Role) error {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}

	s.mu.Lock()
	if _, exists := s.users[username]; exists {
		s.mu.Unlock()
		return fmt.Errorf("user %q already exists", username)
	}
	s.users[username] = User{
		PasswordHash: string(hash),
		Role:         role,
		CreatedAt:    time.Now().UTC(),
	}
	s.mu.Unlock()

	return s.persist(ctx)
}

// Authenticate checks username/password and returns the user if valid.
func (s *UserStore) Authenticate(username, password string) (*User, error) {
	s.mu.RLock()
	user, exists := s.users[username]
	s.mu.RUnlock()

	if !exists {
		return nil, fmt.Errorf("user not found")
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)); err != nil {
		return nil, fmt.Errorf("invalid password")
	}

	return &user, nil
}

// Get returns a user by username.
func (s *UserStore) Get(username string) (*User, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	user, exists := s.users[username]
	if !exists {
		return nil, false
	}
	return &user, true
}

// List returns all usernames and their roles.
func (s *UserStore) List() map[string]User {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make(map[string]User, len(s.users))
	for k, v := range s.users {
		result[k] = v
	}
	return result
}

// ChangePassword updates a user's password.
func (s *UserStore) ChangePassword(ctx context.Context, username, newPassword string) error {
	hash, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}

	s.mu.Lock()
	user, exists := s.users[username]
	if !exists {
		s.mu.Unlock()
		return fmt.Errorf("user %q not found", username)
	}
	user.PasswordHash = string(hash)
	s.users[username] = user
	s.mu.Unlock()

	return s.persist(ctx)
}

// Delete removes a user.
func (s *UserStore) Delete(ctx context.Context, username string) error {
	s.mu.Lock()
	if _, exists := s.users[username]; !exists {
		s.mu.Unlock()
		return fmt.Errorf("user %q not found", username)
	}
	delete(s.users, username)
	s.mu.Unlock()

	return s.persist(ctx)
}

func (s *UserStore) persist(ctx context.Context) error {
	s.mu.RLock()
	data, err := json.MarshalIndent(s.users, "", "  ")
	s.mu.RUnlock()

	if err != nil {
		return err
	}

	return s.client.PutObject(ctx, usersKey, bytes.NewReader(data), int64(len(data)), "application/json", nil)
}
