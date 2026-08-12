package auth

import (
	"strings"
	"testing"
)

func TestValidUsername(t *testing.T) {
	valid := []string{
		"alice",
		"Alice",
		"alice.smith",
		"alice-smith",
		"alice_smith",
		"a",
		"user1",
		strings.Repeat("a", 64),
	}
	for _, username := range valid {
		if !ValidUsername(username) {
			t.Errorf("ValidUsername(%q) = false, want true", username)
		}
	}

	// Every one of these would either escape the caller's storage namespace or
	// resolve to a different one than it appears to name.
	invalid := []string{
		"",
		".",
		"..",
		"../admin",
		"alice/../bob",
		"alice/",
		"/alice",
		"alice bob",
		"alice\n",
		"alice\x00",
		"alice%2fbob",
		"admin@example.com",
		strings.Repeat("a", 65),
	}
	for _, username := range invalid {
		if ValidUsername(username) {
			t.Errorf("ValidUsername(%q) = true, want false", username)
		}
	}
}

// A username reaches object keys directly, so the store must not accept one
// that would place a user outside their own namespace.
func TestUserStoreCreateRejectsUnsafeUsernames(t *testing.T) {
	unsafe := []string{"", "..", "../admin", "alice/bob", "alice bob"}

	for _, username := range unsafe {
		store := testUserStore(t)
		if err := store.Create(t.Context(), username, "secret123", RoleUser); err == nil {
			t.Errorf("Create(%q) succeeded, want an error", username)
		}
		if _, exists := store.users[username]; exists {
			t.Errorf("Create(%q) stored the user despite rejecting it", username)
		}
	}
}
