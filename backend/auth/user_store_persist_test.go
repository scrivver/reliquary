package auth

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"sync"
	"testing"
)

// fakeObjectStore is one in-memory "bucket": a byte slice per key. Two
// UserStores constructed over the same fakeObjectStore stand in for two
// processes sharing one bucket.
type fakeObjectStore struct {
	mu      sync.Mutex
	objects map[string][]byte
}

func newFakeObjectStore() *fakeObjectStore {
	return &fakeObjectStore{objects: make(map[string][]byte)}
}

func (f *fakeObjectStore) GetObject(ctx context.Context, key string) (io.ReadCloser, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	data, ok := f.objects[key]
	if !ok {
		return nil, fmt.Errorf("object %q not found", key)
	}
	return io.NopCloser(bytes.NewReader(append([]byte(nil), data...))), nil
}

func (f *fakeObjectStore) PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string, userMeta map[string]string) error {
	data, err := io.ReadAll(reader)
	if err != nil {
		return err
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	f.objects[key] = data
	return nil
}

// TestUserStore_CrossProcessLostUpdate states the ordering directly: the second
// writer loads before the first writer persists, and persists after it. No
// goroutines or timing luck are involved — the defect is an ordering, not a
// race that needs to be won.
func TestUserStore_CrossProcessLostUpdate(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	server := NewUserStore(backing)
	cli := NewUserStore(backing)

	if err := server.Create(ctx, "bob", "old-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	// Both writers observe the same starting state.
	if err := server.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if err := cli.Load(ctx); err != nil {
		t.Fatal(err)
	}

	// The server mutates and persists.
	if err := server.ChangePassword(ctx, "bob", "new-password"); err != nil {
		t.Fatal(err)
	}

	// The CLI persists from the snapshot it loaded before that change.
	if err := cli.Create(ctx, "carol", "carol-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}

	if _, ok := fresh.Get("carol"); !ok {
		t.Fatal("carol missing: CLI write did not persist")
	}

	if _, err := fresh.Authenticate("bob", "old-password"); err == nil {
		t.Fatal("superseded password still authenticates: change was reverted")
	}
}

// TestUserStore_CrossProcessLostDeactivation is the same ordering applied to a
// deactivation, which is the case with the sharper consequence: a locked-out
// account is live again.
func TestUserStore_CrossProcessLostDeactivation(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	server := NewUserStore(backing)
	cli := NewUserStore(backing)

	if err := server.Create(ctx, "bob", "bob-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	if err := server.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if err := cli.Load(ctx); err != nil {
		t.Fatal(err)
	}

	if err := server.Deactivate(ctx, "bob"); err != nil {
		t.Fatal(err)
	}

	if err := cli.Create(ctx, "carol", "carol-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}

	if _, ok := fresh.Get("carol"); !ok {
		t.Fatal("carol missing: CLI write did not persist")
	}

	user, ok := fresh.Get("bob")
	if !ok {
		t.Fatal("bob missing")
	}
	if user.DeactivatedAt == nil {
		t.Fatal("deactivated account is active again: deactivation was reverted")
	}
	if _, err := fresh.Authenticate("bob", "bob-password"); err == nil {
		t.Fatal("deactivated account still authenticates: deactivation was reverted")
	}
}

// TestUserStore_PersistRoundTrip is the control: with no second writer, the
// same fake carries every mutation through the persist path intact. It fails
// only if the fake or the seam is wrong, which is what makes the two tests
// above evidence of the defect rather than of a broken harness.
func TestUserStore_PersistRoundTrip(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	server := NewUserStore(backing)
	if err := server.Create(ctx, "bob", "old-password", RoleUser); err != nil {
		t.Fatal(err)
	}
	if err := server.ChangePassword(ctx, "bob", "new-password"); err != nil {
		t.Fatal(err)
	}
	if err := server.Create(ctx, "carol", "carol-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}

	if _, ok := fresh.Get("carol"); !ok {
		t.Fatal("carol missing")
	}
	if _, err := fresh.Authenticate("bob", "new-password"); err != nil {
		t.Fatalf("new password should authenticate: %v", err)
	}
	if _, err := fresh.Authenticate("bob", "old-password"); err == nil {
		t.Fatal("superseded password still authenticates")
	}
}

// TestUserStore_StaleWriterRevertsCompletedWrite covers the other direction,
// where the long-running server is the one holding the stale snapshot. The CLI
// runs to completion with no overlap at all; the server then handles an
// ordinary admin action before its next periodic reload and rewrites the whole
// map from the copy it loaded at startup. The window here is bounded by
// userStoreReloadInterval rather than by the CLI's runtime, and the loss is an
// erased account rather than a reverted field.
func TestUserStore_StaleWriterRevertsCompletedWrite(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	server := NewUserStore(backing)
	if err := server.Create(ctx, "bob", "bob-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	// The CLI loads, creates, and exits. Nothing overlaps.
	cli := NewUserStore(backing)
	if err := cli.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if err := cli.Create(ctx, "carol", "carol-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	// The server has not reloaded yet and handles an unrelated mutation.
	if err := server.ChangePassword(ctx, "bob", "new-password"); err != nil {
		t.Fatal(err)
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}

	if _, ok := fresh.Get("carol"); !ok {
		t.Fatal("carol erased: a completed CLI write was reverted by the server's stale snapshot")
	}
}
