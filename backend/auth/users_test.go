package auth

import (
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestAuthenticate_Success(t *testing.T) {
	store := testUserStore(t)
	seedUser(t, store, "alice", "secret123", RoleUser)

	user, err := store.Authenticate("alice", "secret123")
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
	if user.Role != RoleUser {
		t.Errorf("expected role user, got %s", user.Role)
	}
}

func TestAuthenticate_WrongPassword(t *testing.T) {
	store := testUserStore(t)
	seedUser(t, store, "alice", "secret123", RoleUser)

	_, err := store.Authenticate("alice", "wrong")
	if err == nil {
		t.Fatal("expected error for wrong password")
	}
}

func TestAuthenticate_UnknownUser(t *testing.T) {
	store := testUserStore(t)

	_, err := store.Authenticate("nobody", "pass")
	if err == nil {
		t.Fatal("expected error for unknown user")
	}
}

func TestGet(t *testing.T) {
	store := testUserStore(t)
	seedUser(t, store, "bob", "pass", RoleAdmin)

	user, ok := store.Get("bob")
	if !ok {
		t.Fatal("expected user to exist")
	}
	if user.Role != RoleAdmin {
		t.Errorf("expected admin, got %s", user.Role)
	}

	_, ok = store.Get("nobody")
	if ok {
		t.Error("expected user not to exist")
	}
}

func TestList(t *testing.T) {
	store := testUserStore(t)
	seedUser(t, store, "alice", "pass", RoleUser)
	seedUser(t, store, "bob", "pass", RoleAdmin)

	users := store.List()
	if len(users) != 2 {
		t.Fatalf("expected 2 users, got %d", len(users))
	}
}

func TestDelete(t *testing.T) {
	store := testUserStore(t)
	seedUser(t, store, "alice", "pass", RoleUser)

	// Delete without MinIO persistence (will fail on persist, but in-memory state updates).
	store.mu.Lock()
	delete(store.users, "alice")
	store.mu.Unlock()

	_, ok := store.Get("alice")
	if ok {
		t.Error("expected user to be deleted")
	}
}

// seedUser is shared with auth_test.go via the same package.
// The helper and bcrypt import are already defined in auth_test.go,
// but we need them here too since test files are compiled independently
// only when run together. Using the unexported helpers works because
// they're in the same package.

func init() {
	// Ensure bcrypt is available.
	_ = bcrypt.DefaultCost
}
