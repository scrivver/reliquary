package auth

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
)

// TestUserStore_CASRetryConvergesBothWrites is the positive counterpart to the
// lost-update tests: the same interleaving, but now the loser retries against
// fresh state and both writes survive.
func TestUserStore_CASRetryConvergesBothWrites(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	server := NewUserStore(backing)
	cli := NewUserStore(backing)

	if err := server.Create(ctx, "bob", "old-password", RoleUser); err != nil {
		t.Fatal(err)
	}
	if err := server.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if err := cli.Load(ctx); err != nil {
		t.Fatal(err)
	}

	if err := server.ChangePassword(ctx, "bob", "new-password"); err != nil {
		t.Fatal(err)
	}
	// The CLI's snapshot is now stale; the write must retry, not clobber.
	if err := cli.Create(ctx, "carol", "carol-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if _, ok := fresh.Get("carol"); !ok {
		t.Fatal("carol missing: the CLI write was lost")
	}
	if _, err := fresh.Authenticate("bob", "new-password"); err != nil {
		t.Fatalf("bob's password change was lost: %v", err)
	}
	if _, err := fresh.Authenticate("bob", "old-password"); err == nil {
		t.Fatal("superseded password still authenticates")
	}
}

func TestUserStore_CASRetryExhaustion(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	store := NewUserStore(backing)
	if err := store.Create(ctx, "bob", "bob-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	// Every attempt conflicts, so the loop must give up rather than spin.
	backing.mu.Lock()
	backing.failNextPuts = maxCASAttempts
	backing.mu.Unlock()

	err := store.ChangePassword(ctx, "bob", "new-password")
	if err == nil {
		t.Fatal("exhausting the retry budget must report an error, not succeed silently")
	}
	if !strings.Contains(err.Error(), "conflict") {
		t.Fatalf("error should name the cause, got: %v", err)
	}

	// The failed mutation must not have altered in-memory state either.
	if _, err := store.Authenticate("bob", "bob-password"); err != nil {
		t.Fatalf("a failed mutation changed in-memory state: %v", err)
	}
}

// TestUserStore_CASRetrySucceedsWithinBudget checks the loop actually recovers
// rather than only failing cleanly.
func TestUserStore_CASRetrySucceedsWithinBudget(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	store := NewUserStore(backing)
	if err := store.Create(ctx, "bob", "bob-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	backing.mu.Lock()
	backing.failNextPuts = maxCASAttempts - 1
	backing.mu.Unlock()

	if err := store.ChangePassword(ctx, "bob", "new-password"); err != nil {
		t.Fatalf("should have recovered within the retry budget: %v", err)
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := fresh.Authenticate("bob", "new-password"); err != nil {
		t.Fatalf("retry did not persist the change: %v", err)
	}
}

// TestUserStore_ConcurrentCreateSameUsername covers the duplicate-create race.
// Before CAS both writers "succeeded" and one was silently discarded.
func TestUserStore_ConcurrentCreateSameUsername(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	seed := NewUserStore(backing)
	if err := seed.Create(ctx, "existing", "pw", RoleUser); err != nil {
		t.Fatal(err)
	}

	a := NewUserStore(backing)
	b := NewUserStore(backing)
	if err := a.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if err := b.Load(ctx); err != nil {
		t.Fatal(err)
	}

	errA := a.Create(ctx, "dave", "from-a", RoleUser)
	errB := b.Create(ctx, "dave", "from-b", RoleUser)

	if (errA == nil) == (errB == nil) {
		t.Fatalf("exactly one create should succeed: errA=%v errB=%v", errA, errB)
	}
	loser := errA
	if loser == nil {
		loser = errB
	}
	if !strings.Contains(loser.Error(), "already exists") {
		t.Fatalf("loser should report the conflict plainly, got: %v", loser)
	}
}

func TestUserStore_SeedRaceCreatesOneAdmin(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	a := NewUserStore(backing)
	b := NewUserStore(backing)

	// Both replicas start against an empty bucket and both try to seed.
	if err := a.Seed(ctx, "admin", "admin"); err != nil {
		t.Fatalf("first seed: %v", err)
	}
	if err := b.Seed(ctx, "admin", "admin"); err != nil {
		t.Fatalf("a replica losing the seed race must still start: %v", err)
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if got := len(fresh.List()); got != 1 {
		t.Fatalf("expected exactly one seeded admin, got %d", got)
	}
}

// TestUserStore_SeedSkipsWhenAnotherWriterSeededFirst exercises the path where
// the losing replica has never loaded, so it only discovers the existing store
// through the refused conditional write.
func TestUserStore_SeedSkipsWhenAnotherWriterSeededFirst(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	first := NewUserStore(backing)
	if err := first.Create(ctx, "someone", "pw", RoleUser); err != nil {
		t.Fatal(err)
	}

	// This store still believes the bucket is empty.
	late := NewUserStore(backing)
	if err := late.Seed(ctx, "admin", "admin"); err != nil {
		t.Fatalf("seed against an already-populated store must no-op: %v", err)
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if _, ok := fresh.Get("admin"); ok {
		t.Fatal("seed created an admin over a non-empty store")
	}
	if _, ok := fresh.Get("someone"); !ok {
		t.Fatal("seed erased the existing user")
	}
}

func TestUserStore_TerminalErrorNotRetried(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	store := NewUserStore(backing)
	if err := store.Create(ctx, "bob", "pw", RoleUser); err != nil {
		t.Fatal(err)
	}
	before := backing.putCount()

	if err := store.ChangePassword(ctx, "nobody", "pw"); err == nil {
		t.Fatal("expected an error for an unknown user")
	}
	if err := store.Delete(ctx, "nobody"); err == nil {
		t.Fatal("expected an error for an unknown user")
	}

	// "not found" is an answer, not a conflict: it must not reach storage at
	// all, let alone burn the retry budget.
	if got := backing.putCount(); got != before {
		t.Fatalf("terminal errors issued %d writes, want 0", got-before)
	}
}

func TestUserStore_NoChangeSkipsWrite(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	store := NewUserStore(backing)
	if err := store.Create(ctx, "bob", "pw", RoleUser); err != nil {
		t.Fatal(err)
	}
	before := backing.putCount()

	// The store is non-empty, so Seed has nothing to do and must not write.
	if err := store.Seed(ctx, "admin", "admin"); err != nil {
		t.Fatal(err)
	}
	if got := backing.putCount(); got != before {
		t.Fatalf("a no-op seed issued %d writes, want 0", got-before)
	}
}

func TestUserStore_UnbackedStoreStillMutates(t *testing.T) {
	ctx := context.Background()
	store := &UserStore{users: make(map[string]User)}

	if err := store.Create(ctx, "bob", "pw", RoleUser); err != nil {
		t.Fatalf("an unbacked store must still mutate in memory: %v", err)
	}
	if _, err := store.Authenticate("bob", "pw"); err != nil {
		t.Fatal(err)
	}
	if err := store.Delete(ctx, "bob"); err != nil {
		t.Fatal(err)
	}
	if _, ok := store.Get("bob"); ok {
		t.Fatal("delete did not apply")
	}
}

// TestUserStore_ParallelMutationsAllLand is the stress counterpart to the
// deterministic tests: many writers over one bucket, every write must survive.
func TestUserStore_ParallelMutationsAllLand(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	// One store shared by many goroutines is the in-process case saveMu already
	// covered; separate stores are the cross-process case CAS adds.
	const writers = 8
	var wg sync.WaitGroup
	errs := make([]error, writers)

	for i := 0; i < writers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			store := NewUserStore(backing)
			if err := store.Load(ctx); err != nil {
				errs[i] = err
				return
			}
			errs[i] = store.Create(ctx, fmt.Sprintf("user%d", i), "pw", RoleUser)
		}(i)
	}
	wg.Wait()

	created := 0
	for i, err := range errs {
		if err == nil {
			created++
			continue
		}
		// Losing every retry under this much contention is a legitimate
		// outcome; silently losing a write is not.
		if !strings.Contains(err.Error(), "conflict") {
			t.Fatalf("writer %d failed unexpectedly: %v", i, err)
		}
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if got := len(fresh.List()); got != created {
		t.Fatalf("%d creates reported success but %d landed: writes were lost", created, got)
	}
	t.Logf("%d/%d writers succeeded, all persisted", created, writers)
}

type flakyNotifier struct {
	mu       sync.Mutex
	calls    int
	etags    []string
	failWith error
}

func (n *flakyNotifier) NotifyChanged(ctx context.Context, etag string) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.calls++
	n.etags = append(n.etags, etag)
	return n.failWith
}

// TestUserStore_NotifierFailureDoesNotFailMutation is the contract the whole
// invalidation design rests on: correctness comes from the conditional write,
// so a broker problem may cost convergence latency but must never cost a write.
func TestUserStore_NotifierFailureDoesNotFailMutation(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	notifier := &flakyNotifier{failWith: fmt.Errorf("broker unreachable")}
	store := NewUserStore(backing)
	store.SetChangeNotifier(notifier)

	if err := store.Create(ctx, "bob", "pw", RoleUser); err != nil {
		t.Fatalf("a failing notifier must not fail the mutation: %v", err)
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}
	if _, ok := fresh.Get("bob"); !ok {
		t.Fatal("the write did not persist")
	}
}

func TestUserStore_NotifierReceivesNewETag(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	notifier := &flakyNotifier{}
	store := NewUserStore(backing)
	store.SetChangeNotifier(notifier)

	if err := store.Create(ctx, "bob", "pw", RoleUser); err != nil {
		t.Fatal(err)
	}
	if err := store.ChangePassword(ctx, "bob", "pw2"); err != nil {
		t.Fatal(err)
	}

	notifier.mu.Lock()
	defer notifier.mu.Unlock()
	if notifier.calls != 2 {
		t.Fatalf("expected one notification per mutation, got %d", notifier.calls)
	}
	// The announced etag must be the version just written, so a receiver
	// already on it can skip the reload.
	if notifier.etags[len(notifier.etags)-1] != store.CurrentETag() {
		t.Fatalf("announced etag %q is not the version written (%q)",
			notifier.etags[len(notifier.etags)-1], store.CurrentETag())
	}
}

// A terminal error never reaches storage, so it must not announce a change
// either.
func TestUserStore_NoNotificationWithoutAWrite(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore()

	notifier := &flakyNotifier{}
	store := NewUserStore(backing)
	if err := store.Create(ctx, "bob", "pw", RoleUser); err != nil {
		t.Fatal(err)
	}
	store.SetChangeNotifier(notifier)

	if err := store.Delete(ctx, "nobody"); err == nil {
		t.Fatal("expected an error")
	}
	if err := store.Seed(ctx, "admin", "admin"); err != nil {
		t.Fatal(err)
	}

	notifier.mu.Lock()
	defer notifier.mu.Unlock()
	if notifier.calls != 0 {
		t.Fatalf("announced %d changes without writing anything", notifier.calls)
	}
}
