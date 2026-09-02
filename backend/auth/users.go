package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
//
// Both methods are ETag-aware: the user object is shared by more than one
// process, so every write is conditional on the version it was derived from.
type objectStore interface {
	// GetObjectWithETag returns the object bytes and the ETag identifying the
	// version read. ok is false when the object does not exist yet.
	GetObjectWithETag(ctx context.Context, key string) (data []byte, etag string, ok bool, err error)
	// PutObjectIfUnchanged writes only if the stored ETag still equals
	// expectedETag; an empty expectedETag means "only if absent". It reports
	// storage.ErrPreconditionFailed when another writer got there first.
	PutObjectIfUnchanged(ctx context.Context, key string, data []byte, contentType, expectedETag string) (newETag string, err error)
}

type UserStore struct {
	client objectStore
	mu     sync.RWMutex
	users  map[string]User // username → User
	// etag identifies the persisted version that users was loaded from. It is
	// the compare half of every compare-and-swap: a write carrying a superseded
	// etag is refused rather than silently reverting the newer version.
	etag string
	// notifier tells other replicas that the store advanced, so they reload
	// promptly rather than waiting out StartPeriodicReload. Optional: a nil
	// notifier just means slower convergence.
	notifier ChangeNotifier
	// saveMu serializes read-modify-persist sequences against each other and
	// against reloads, so a reload landing mid-mutation cannot cause the
	// pending write to persist the state it just overwrote.
	saveMu sync.Mutex
}

// ChangeNotifier is told that the persisted user store advanced to a new
// version.
//
// Implementations are best-effort: a failure here must never fail the mutation
// that triggered it. Correctness comes from the conditional write; this only
// shortens how long other replicas serve a stale view.
type ChangeNotifier interface {
	NotifyChanged(ctx context.Context, etag string) error
}

// SetChangeNotifier attaches a notifier. A nil notifier disables notification,
// leaving StartPeriodicReload as the only convergence path.
func (s *UserStore) SetChangeNotifier(n ChangeNotifier) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.notifier = n
}

// CurrentETag reports the persisted version currently held in memory.
func (s *UserStore) CurrentETag() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.etag
}

// Reload re-reads the persisted store, for callers reacting to a change made
// elsewhere.
func (s *UserStore) Reload(ctx context.Context) error {
	_, err := s.reload(ctx)
	return err
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
// resulting user count.
func (s *UserStore) reload(ctx context.Context) (int, error) {
	s.saveMu.Lock()
	defer s.saveMu.Unlock()

	if err := s.reloadLocked(ctx); err != nil {
		return s.count(), err
	}
	return s.count(), nil
}

// reloadLocked is reload without acquiring saveMu, for callers that already
// hold it. mutate re-reads through this path after losing a race, so taking
// saveMu again here would self-deadlock on the first conflict.
//
// An unreadable or unparseable object is an error rather than a silent
// fallback. The current users are kept either way — a transient read failure
// must not empty a running store — but the caller is told, because writing on
// top of a store whose contents are unknown is how a corrupt object gets
// overwritten with a fresh one.
func (s *UserStore) reloadLocked(ctx context.Context) error {
	data, etag, ok, err := s.client.GetObjectWithETag(ctx, usersKey)
	if err != nil {
		return fmt.Errorf("read user store: %w", err)
	}

	if !ok || len(data) == 0 {
		// No persisted object. The in-memory users are kept, and the empty etag
		// makes the next write create-only, so a store that was deleted out from
		// under a running process is restored rather than raced over.
		slog.Info("user store not found, starting empty")
		s.mu.Lock()
		s.etag = ""
		s.mu.Unlock()
		return nil
	}

	users := make(map[string]User)
	if err := json.Unmarshal(data, &users); err != nil {
		return fmt.Errorf("parse user store: %w", err)
	}

	s.mu.Lock()
	s.users = users
	s.etag = etag
	s.mu.Unlock()

	return nil
}

func (s *UserStore) count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.users)
}

// cloneUsers copies the map so a mutation attempt can be abandoned without
// having touched the live state. User is all value types except DeactivatedAt,
// which is only ever replaced, never written through, so the pointer may be
// shared.
func cloneUsers(users map[string]User) map[string]User {
	clone := make(map[string]User, len(users))
	for name, user := range users {
		clone[name] = user
	}
	return clone
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
//
// The emptiness check is repeated inside the mutation so that replicas starting
// together cannot both seed. The first write is create-only, so the loser is
// refused, re-reads, finds the store non-empty, and no-ops instead of failing
// to boot.
func (s *UserStore) Seed(ctx context.Context, username, password string) error {
	s.mu.RLock()
	count := len(s.users)
	s.mu.RUnlock()

	if count > 0 {
		return nil
	}

	if !ValidUsername(username) {
		return fmt.Errorf("username %q must be 1-64 characters of letters, digits, dot, dash or underscore", username)
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}

	slog.Info("seeding initial admin user", "username", username)
	return s.mutate(ctx, func(users map[string]User) error {
		if len(users) > 0 {
			slog.Info("user store already seeded by another writer, skipping")
			return errNoChange
		}
		users[username] = User{
			PasswordHash: string(hash),
			Role:         RoleAdmin,
			CreatedAt:    time.Now().UTC(),
		}
		return nil
	})
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

	// The existence check runs inside the mutation so that a retry re-evaluates
	// it against fresh state: two processes creating the same username now
	// produce one success and one clean error, rather than both "succeeding".
	return s.mutate(ctx, func(users map[string]User) error {
		if _, exists := users[username]; exists {
			return fmt.Errorf("user %q already exists", username)
		}
		users[username] = User{
			PasswordHash: string(hash),
			Role:         role,
			CreatedAt:    time.Now().UTC(),
		}
		return nil
	})
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

	return s.mutate(ctx, func(users map[string]User) error {
		user, exists := users[username]
		if !exists {
			return fmt.Errorf("user %q not found", username)
		}
		user.PasswordHash = string(hash)
		// Changing a password is how a user ends a session they no longer trust,
		// so it must invalidate tokens already issued. Incrementing inside the
		// mutation means it counts up from the freshly read value, so a
		// concurrent revocation cannot be un-bumped.
		user.TokenVersion++
		users[username] = user
		return nil
	})
}

// Deactivate disables a user without deleting their stored files.
func (s *UserStore) Deactivate(ctx context.Context, username string) error {
	return s.mutate(ctx, func(users map[string]User) error {
		user, exists := users[username]
		if !exists {
			return fmt.Errorf("user %q not found", username)
		}
		now := time.Now().UTC()
		user.DeactivatedAt = &now
		// Deactivation is checked on every request, but bumping the version also
		// covers tokens issued before a lockout that is later reversed.
		user.TokenVersion++
		users[username] = user
		return nil
	})
}

// Activate re-enables a deactivated user.
func (s *UserStore) Activate(ctx context.Context, username string) error {
	return s.mutate(ctx, func(users map[string]User) error {
		user, exists := users[username]
		if !exists {
			return fmt.Errorf("user %q not found", username)
		}
		user.DeactivatedAt = nil
		users[username] = user
		return nil
	})
}

// Delete removes a user.
func (s *UserStore) Delete(ctx context.Context, username string) error {
	return s.mutate(ctx, func(users map[string]User) error {
		if _, exists := users[username]; !exists {
			return fmt.Errorf("user %q not found", username)
		}
		delete(users, username)
		return nil
	})
}

// errNoChange lets a mutation report that the state it wanted is already the
// state that is stored, so mutate returns successfully without writing. Without
// it a no-op would still issue a conditional write, bumping the version and
// forcing every other writer to retry for nothing.
var errNoChange = errors.New("user store: no change required")

// maxCASAttempts bounds the compare-and-swap retry loop. Reaching it means
// either genuine heavy contention, which this deployment shape does not
// produce, or a bug that stops the loop converging — so it is reported rather
// than retried forever.
const maxCASAttempts = 5

// mutate applies fn to the persisted user store under compare-and-swap.
//
// The whole map is rewritten on every save, so a writer working from a stale
// snapshot does not lose one field — it reverts everything written since it
// loaded. The conditional write refuses that, and fn is re-applied to a freshly
// read snapshot instead.
//
// fn MUST be safe to run more than once. It receives a private copy of the user
// map and may mutate it freely. Anything expensive or non-deterministic —
// bcrypt hashing above all — belongs outside the loop, computed once by the
// caller and closed over.
//
// An error from fn is terminal and returned as-is: "user not found" is an
// answer, not a conflict, and retrying it would only produce it again.
func (s *UserStore) mutate(ctx context.Context, fn func(users map[string]User) error) error {
	s.saveMu.Lock()
	defer s.saveMu.Unlock()

	// An unbacked store holds users in memory only and has nothing to contend
	// with, so it applies the change directly.
	if s.client == nil {
		s.mu.Lock()
		defer s.mu.Unlock()
		return fn(s.users)
	}

	for attempt := 0; attempt < maxCASAttempts; attempt++ {
		if attempt > 0 {
			// Another writer won the last round. Re-read before re-applying, or
			// the retry would carry the same superseded etag and fail forever.
			if err := s.reloadLocked(ctx); err != nil {
				return err
			}
		}

		s.mu.RLock()
		working, etag := cloneUsers(s.users), s.etag
		s.mu.RUnlock()

		if err := fn(working); err != nil {
			if errors.Is(err, errNoChange) {
				return nil
			}
			return err
		}

		data, err := json.MarshalIndent(working, "", "  ")
		if err != nil {
			return err
		}

		newETag, err := s.client.PutObjectIfUnchanged(ctx, usersKey, data, "application/json", etag)
		if errors.Is(err, storage.ErrPreconditionFailed) {
			slog.Debug("user store changed underneath a write, retrying", "attempt", attempt+1)
			continue
		}
		if err != nil {
			return err
		}

		s.mu.Lock()
		s.users, s.etag = working, newETag
		notifier := s.notifier
		s.mu.Unlock()

		if notifier != nil {
			// Best effort by contract: the write is already durable, so a
			// failure here costs convergence latency, not correctness.
			if err := notifier.NotifyChanged(ctx, newETag); err != nil {
				slog.Warn("failed to announce user store change; replicas will converge on the next periodic reload", "error", err)
			}
		}

		return nil
	}

	return fmt.Errorf("user store: %d concurrent modification conflicts, giving up", maxCASAttempts)
}
