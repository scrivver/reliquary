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
)

const usersKey = "admin/users.json"

type Role string

const (
	RoleAdmin Role = "admin"
	RoleUser  Role = "user"
)

type User struct {
	PasswordHash  string     `json:"password_hash"`
	Role          Role       `json:"role"`
	CreatedAt     time.Time  `json:"created_at"`
	DeactivatedAt *time.Time `json:"deactivated_at,omitempty"`
	// TokenVersion invalidates previously issued tokens. Each token records the
	// version current at login; bumping it here leaves every existing token
	// mismatched and therefore rejected. A timestamp floor cannot do this
	// reliably, because a JWT's iat has one-second resolution and so cannot
	// order a token against a change made in the same second. Accounts
	// predating this field carry version 0, matching tokens that have no
	// version claim.
	TokenVersion int `json:"token_version,omitempty"`
}

// objectStore is the slice of object storage the user store needs. Declaring
// it here rather than taking a *storage.Client keeps the persistence round trip
// substitutable in tests, mirroring archiveStore in
// backend/storage/restore_archive.go.
type objectStore interface {
	GetObject(ctx context.Context, key string) (io.ReadCloser, error)
	PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string, userMeta map[string]string) error
}

type UserStore struct {
	client objectStore
	mu     sync.RWMutex
	users  map[string]User // username → User
	// saveMu serializes read-modify-persist sequences against each other and
	// against reloads, so a reload landing mid-mutation cannot cause the
	// pending write to persist the state it just overwrote.
	saveMu sync.Mutex
}

func NewUserStore(client objectStore) *UserStore {
	return &UserStore{
		client: client,
		users:  make(map[string]User),
	}
}

// Load reads the user store from MinIO.
func (s *UserStore) Load(ctx context.Context) error {
	n, err := s.reload(ctx)
	if err != nil {
		return err
	}
	slog.Info("user store loaded", "users", n)
	return nil
}

// reload replaces the in-memory users with the persisted copy, returning the
// resulting user count. The current state is kept on any failure — a missing,
// unreadable, or malformed object must not empty a running store.
func (s *UserStore) reload(ctx context.Context) (int, error) {
	s.saveMu.Lock()
	defer s.saveMu.Unlock()

	obj, err := s.client.GetObject(ctx, usersKey)
	if err != nil {
		slog.Info("user store not found, starting empty")
		return s.count(), nil
	}
	defer obj.Close()

	data, err := io.ReadAll(obj)
	if err != nil || len(data) == 0 {
		return s.count(), nil
	}

	users := make(map[string]User)
	if err := json.Unmarshal(data, &users); err != nil {
		slog.Warn("failed to parse user store, keeping current users", "error", err)
		return s.count(), nil
	}

	s.mu.Lock()
	s.users = users
	s.mu.Unlock()

	return len(users), nil
}

func (s *UserStore) count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.users)
}

// userStoreReloadInterval bounds how long a revocation made by another API
// replica takes to apply here.
const userStoreReloadInterval = 30 * time.Second

// StartPeriodicReload re-reads the persisted user store on an interval, so that
// a deactivation, deletion, or password change performed by another replica
// takes effect here within one interval. Without it, revocation only applies to
// the process that handled the change.
func (s *UserStore) StartPeriodicReload(ctx context.Context) {
	go func() {
		ticker := time.NewTicker(userStoreReloadInterval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if _, err := s.reload(ctx); err != nil {
					slog.Warn("user store reload failed", "error", err)
				}
			}
		}
	}()
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
	if !ValidUsername(username) {
		return fmt.Errorf("username %q must be 1-64 characters of letters, digits, dot, dash or underscore", username)
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}

	s.saveMu.Lock()
	defer s.saveMu.Unlock()

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
	if user.DeactivatedAt != nil {
		return nil, fmt.Errorf("user is deactivated")
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

	s.saveMu.Lock()
	defer s.saveMu.Unlock()

	s.mu.Lock()
	user, exists := s.users[username]
	if !exists {
		s.mu.Unlock()
		return fmt.Errorf("user %q not found", username)
	}
	user.PasswordHash = string(hash)
	// Changing a password is how a user ends a session they no longer trust,
	// so it must invalidate tokens already issued.
	user.TokenVersion++
	s.users[username] = user
	s.mu.Unlock()

	return s.persist(ctx)
}

// Deactivate disables a user without deleting their stored files.
func (s *UserStore) Deactivate(ctx context.Context, username string) error {
	s.saveMu.Lock()
	defer s.saveMu.Unlock()

	s.mu.Lock()
	user, exists := s.users[username]
	if !exists {
		s.mu.Unlock()
		return fmt.Errorf("user %q not found", username)
	}
	now := time.Now().UTC()
	user.DeactivatedAt = &now
	// Deactivation is checked on every request, but bumping the version also
	// covers tokens issued before a lockout that is later reversed.
	user.TokenVersion++
	s.users[username] = user
	s.mu.Unlock()

	return s.persist(ctx)
}

// Activate re-enables a deactivated user.
func (s *UserStore) Activate(ctx context.Context, username string) error {
	s.saveMu.Lock()
	defer s.saveMu.Unlock()

	s.mu.Lock()
	user, exists := s.users[username]
	if !exists {
		s.mu.Unlock()
		return fmt.Errorf("user %q not found", username)
	}
	user.DeactivatedAt = nil
	s.users[username] = user
	s.mu.Unlock()

	return s.persist(ctx)
}

// Delete removes a user.
func (s *UserStore) Delete(ctx context.Context, username string) error {
	s.saveMu.Lock()
	defer s.saveMu.Unlock()

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

	// An unbacked store holds users in memory only and has nowhere to write.
	if s.client == nil {
		return nil
	}

	return s.client.PutObject(ctx, usersKey, bytes.NewReader(data), int64(len(data)), "application/json", nil)
}
