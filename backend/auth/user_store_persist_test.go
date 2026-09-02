package auth

import (
	"context"
	"fmt"
	"sync"
	"testing"

	"reliquary-be/storage"
)

// fakeObjectStore is one in-memory "bucket": a versioned byte slice per key.
// Two UserStores constructed over the same fakeObjectStore stand in for two
// processes sharing one bucket.
//
// It enforces the same conditional-write contract as storage.Client, verified
// against a live MinIO in storage/conditional_integration_test.go. If the two
// ever drift, that integration test is the one that catches it.
type fakeObjectStore struct {
	mu      sync.Mutex
	objects map[string]fakeObject

	// puts counts accepted and refused writes, so a test can assert that a
	// terminal error never reached storage.
	puts int
	// failNextPuts forces the next n writes to be refused as conflicts,
	// making the retry path reachable without goroutines or timing.
	failNextPuts int
	etagSeq      int
}

type fakeObject struct {
	data []byte
	etag string
}

func newFakeObjectStore() *fakeObjectStore {
	return &fakeObjectStore{objects: make(map[string]fakeObject)}
}

func (f *fakeObjectStore) GetObjectWithETag(ctx context.Context, key string) ([]byte, string, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	obj, ok := f.objects[key]
	if !ok {
		return nil, "", false, nil
	}
	return append([]byte(nil), obj.data...), obj.etag, true, nil
}

func (f *fakeObjectStore) PutObjectIfUnchanged(
	ctx context.Context,
	key string,
	data []byte,
	contentType string,
	expectedETag string,
) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.puts++
	if f.failNextPuts > 0 {
		f.failNextPuts--
		return "", fmt.Errorf("%w: forced by test", storage.ErrPreconditionFailed)
	}

	current, exists := f.objects[key]
	switch {
	case expectedETag == "" && exists:
		// Create-only against an existing object.
		return "", fmt.Errorf("%w: %q already exists", storage.ErrPreconditionFailed, key)
	case expectedETag != "" && !exists:
		return "", fmt.Errorf("%w: %q does not exist", storage.ErrPreconditionFailed, key)
	case expectedETag != "" && expectedETag != current.etag:
		return "", fmt.Errorf("%w: %q changed since it was read", storage.ErrPreconditionFailed, key)
	}

	f.etagSeq++
	etag := fmt.Sprintf("etag-%d", f.etagSeq)
	f.objects[key] = fakeObject{data: append([]byte(nil), data...), etag: etag}
	return etag, nil
}

func (f *fakeObjectStore) putCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.puts
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
