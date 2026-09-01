# User Store Cross-Process Write Plan

## Problem

`UserStore` serialises read-modify-persist sequences with an in-process mutex,
but the user object it persists is shared by more than one process. Any two
processes holding a `UserStore` against the same bucket can silently revert each
other's writes.

`saveMu` (`backend/auth/users.go:49`) correctly serialises every mutator —
`Create:148`, `ChangePassword:219`, `Deactivate:245`, `Activate:267`,
`Delete:285` — against each other and against `reload:72`. Lock ordering is
consistently `saveMu` then `mu`, so the single-process behaviour is sound.

A mutex is a local variable. It excludes goroutines in one address space and
nothing else.

`persist:300` marshals the **entire** `users` map from the calling process's
in-memory copy. A lost update therefore does not drop one field — it restores
that process's whole snapshot over everything written since it loaded.

There are currently two writers:

1. The API server (`backend/main.go`), long-running.
2. `reliquary-user` (`backend/cmd/reliquary-user/main.go:66-70`), which builds
   its own `UserStore`, calls `Load`, mutates, and persists.

The CLI is a second writer that was never classified as one.

## Impact

An admin action performed through the API during a `reliquary-user` invocation
is reverted, with no error and no log line. So is a CLI account creation
performed shortly before an API mutation — see The Window — Corrected below.

The three cases that matter:

- A password change is undone. The superseded password authenticates again.
- A deactivated account is reactivated. `Deactivate` through the API, run the
  CLI inside the window, and the account is live again.
- A newly created account disappears. Create a user with the CLI, let it exit,
  and any API mutation within the next 30 seconds erases it.

`StartPeriodicReload:115` then converges the server onto the CLI's version
within `userStoreReloadInterval` (`:109`, 30s), so the system looks consistent
afterwards. Nothing surfaces the loss.

### The Window — Corrected

An earlier revision of this document described the window as the full runtime of
one CLI invocation — from `Load` at `main.go:67` to the `persist` at the end of
`Create`, so two object-storage round trips plus one
`bcrypt.GenerateFromPassword` at `DefaultCost`, realistically a few hundred
milliseconds dominated by hashing.

That is correct, but it is only the direction in which the CLI clobbers the
server. The defect is symmetric, and the other direction has a much wider
window.

The server is long-running and holds its in-memory copy between reloads. Once
the CLI has persisted, the server's copy is stale until its next
`StartPeriodicReload` tick — **up to `userStoreReloadInterval`, 30 seconds**.
Any admin mutation the server handles inside that interval persists its stale
whole-map snapshot and erases the CLI's write. The CLI need not still be
running; it can have exited cleanly some seconds earlier.

So the periodic reload is both the thing that hides the first direction and the
thing that bounds the second. Two windows, not one:

| Direction | Window | Loss |
|---|---|---|
| CLI persists over server | CLI runtime, a few hundred ms | A field reverts — superseded password authenticates, deactivated account is live |
| Server persists over CLI | Up to 30s after the CLI exits | A whole account created by the CLI disappears |

The second is both wider and worse. `TestUserStore_StaleWriterRevertsCompletedWrite`
covers it.

This changes the mitigation advice. "Do not run the CLI while an admin action is
in flight" does not cover the defect: the CLI can complete entirely and an
unrelated API mutation up to 30 seconds later still reverts it. The only sound
operational guidance today is to keep admin mutations out of a 30-second window
*after* every CLI invocation as well as during it.

Likelihood is still low. `reliquary-user` is a bootstrap and maintenance tool,
usually run when nothing else is happening, and admin mutations are rare on a
personal deployment. This is not believed to have occurred in practice. The
widened window raises the exposure but does not change that assessment, and does
not change the recommendation below — Option B removes the second writer and so
closes both directions at once.

Not externally exploitable: an attacker cannot cause the operator to run the
CLI at a chosen moment. Treat this as a correctness defect with security
consequences, not a vulnerability.

Applies only to built-in password auth. In OIDC mode the backend does not own
accounts and never writes the user object.

## Why the Current Tests Miss It

`testUserStore` (`backend/auth/auth_test.go:24-29`) constructs
`&UserStore{users: make(map[string]User)}` with a nil client. `persist:300`
returns early when `client == nil`, so no existing test exercises the
persistence round trip at all — and the defect lives entirely in that round
trip.

`UserStore.client` was a concrete `*storage.Client` (`:43`), so there was no
seam to substitute a fake. That is the one statement here now out of date: the
seam has since landed (see Prerequisite — Storage Seam), and the round trip is
exercised. The rest of this section still describes why the *pre-existing* tests
miss the defect — `testUserStore` continues to construct an unbacked store, and
should, since those tests are about auth behaviour rather than persistence.

## Reproduction

**Status: reproduced and confirmed.** The storage seam and the tests below have
landed; the fix has not. The tests fail against current `main` on purpose, and
are the specification for the fix.

The defect is an ordering, not a timing coincidence: the second writer must
`Load` before the first writer's `persist`, and `persist` after it. A test can
state that ordering directly — no goroutines, sleeps, or scheduling luck. That
prediction held: every run fails deterministically, with no flakiness and no
scheduling dependence.

### What Was Confirmed

Everything the Problem section asserts was checked against the source and holds:
the `saveMu` → `mu` lock ordering, `persist:300` marshalling the whole map, the
`client == nil` early return that makes today's tests skip the round trip
entirely, and `reliquary-user/main.go:66-70` as an unclassified second writer.

Tests live in `backend/auth/user_store_persist_test.go`, over a
`fakeObjectStore` holding one `[]byte` per key. Current results:

| Test | Result | Asserts |
|---|---|---|
| `TestUserStore_CrossProcessLostUpdate` | **FAIL** (expected) | Superseded password authenticates after the CLI reverts a `ChangePassword` |
| `TestUserStore_CrossProcessLostDeactivation` | **FAIL** (expected) | Deactivated account is live again after the CLI reverts a `Deactivate` |
| `TestUserStore_StaleWriterRevertsCompletedWrite` | **FAIL** (expected) | A completed CLI account creation is erased by the server's stale snapshot |
| `TestUserStore_PersistRoundTrip` | PASS | Control — one writer, same fake, every mutation survives |

The control matters. It exercises the same fake and the same persist path with
no second writer, and passes. Without it the three failures would be equally
consistent with a broken harness; with it they isolate the defect to
cross-process ordering.

The seam refactor is behaviour-neutral: `go build ./...` and `go vet ./...` are
clean, and the only failures in the suite are the three above.

### The Test As Written

```go
func TestUserStore_CrossProcessLostUpdate(t *testing.T) {
	ctx := context.Background()
	backing := newFakeObjectStore() // one shared "bucket"

	// Two independent stores over one bucket == two processes.
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

	// Server mutates and persists.
	if err := server.ChangePassword(ctx, "bob", "new-password"); err != nil {
		t.Fatal(err)
	}

	// CLI persists from the snapshot it loaded before that change.
	if err := cli.Create(ctx, "carol", "carol-password", RoleUser); err != nil {
		t.Fatal(err)
	}

	fresh := NewUserStore(backing)
	if err := fresh.Load(ctx); err != nil {
		t.Fatal(err)
	}

	// The CLI's write landed.
	if _, ok := fresh.Get("carol"); !ok {
		t.Fatal("carol missing: CLI write did not persist")
	}

	// And it took bob's password change with it.
	if _, err := fresh.Authenticate("bob", "old-password"); err == nil {
		t.Fatal("superseded password still authenticates: change was reverted")
	}
}
```

The `Deactivate` variant asserts the account is active again, and
`TestUserStore_StaleWriterRevertsCompletedWrite` covers the reverse direction
described under The Window — Corrected.

Reproducing by hand against a live deployment is easier than first assessed. The
CLI-clobbers-server direction does need an API mutation inside a sub-second
window, and widening it temporarily (raise the bcrypt cost, or sleep between
`Load` and `Create` in the CLI) makes that observable. But the reverse direction
needs no window manipulation at all: run `reliquary-user create-user`, let it
exit, then perform any admin mutation through the API within 30 seconds. The new
account is gone, with no error and no log line.

## Goal

Two processes must not be able to silently revert each other's writes to the
user object.

## Non-Goals

- Do not add a database.
- Do not depend on any object-storage feature that is not universally
  implemented across S3-compatible backends.
- Do not change the auth API contract.
- Do not alter OIDC or proxy auth behaviour.

## Option A — Conditional Writes

Read the user object with its version, make the `PutObject` conditional on that
version being unchanged, and reload-and-retry on conflict. Compare-and-swap at
the storage layer.

Correct, and fixes the whole class at once: the same pattern is used by the file
index and the checksum index, and all three would benefit.

Blocked by a project constraint rather than by difficulty. Conditional write
support across S3-compatible implementations is uneven, and running against any
compatible backend is a deliberate premise of this project. Adopting CAS means
either dropping that guarantee or introducing a capability-detection path with a
fallback — which reintroduces the unsafe path it was meant to remove.

## Option B — One Writer

Remove the second writer. `reliquary-user` talks to the running API instead of
the bucket, so the constraint `saveMu` already assumes becomes true.

Weaker in theory and adequate in practice. It does not make the store safe
against concurrent processes in general; it removes the only process that
creates the situation.

Costs to account for:

- The CLI needs an admin credential and a reachable API, where it currently
  needs only bucket access.
- Bootstrapping the first admin account must still work before any account
  exists. `Seed:134` covers the empty-store case and should keep its direct
  path, guarded so it refuses when the store is non-empty.
- Offline recovery against a bucket with no server running is lost, unless an
  explicit break-glass flag is retained.

## Recommendation

Option B, with the storage seam landed first.

Option A is the better engineering answer and should be revisited if backend
portability requirements ever relax, or if the file and checksum indexes hit the
same defect under real load.

## Prerequisite — Storage Seam

Replace the concrete `client *storage.Client` field (`:43`) with a narrow
interface declared in `backend/auth`:

```go
type objectStore interface {
	GetObject(ctx context.Context, key string) (io.ReadCloser, error)
	PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string, userMeta map[string]string) error
}
```

`*storage.Client` satisfies this already. This mirrors the existing
`archiveStore` interface in `backend/storage/restore_archive.go:12`, so it
follows a convention the codebase has set rather than introducing one.

**Landed.** `*storage.Client` satisfied the interface with no change, and all
three callers (`main.go:56`, `cmd/rebuild-file-index/main.go:47`,
`cmd/reliquary-user/main.go:66`) pass one, so the refactor was behaviour-neutral.
The `client == nil` guard in `persist` still works as intended: the field's zero
value is now a nil interface, so `testUserStore`'s unbacked store keeps its early
return.

This was landed independently of any fix, as intended — it is what makes the
defect testable, and the regression tests exist and fail before the behaviour
changes.

## Implementation Steps

1. ~~Extract the `objectStore` interface and update `NewUserStore`. No behaviour
   change.~~ **Done.**
2. ~~Add an in-memory fake implementing it, holding one `[]byte` per key.~~
   **Done** — `fakeObjectStore` in `backend/auth/user_store_persist_test.go`.
3. ~~Add `TestUserStore_CrossProcessLostUpdate` and a `Deactivate` variant.
   Confirm both fail.~~ **Done**, plus
   `TestUserStore_StaleWriterRevertsCompletedWrite` for the reverse direction and
   `TestUserStore_PersistRoundTrip` as a passing control. All three defect tests
   fail as intended.
4. Add an admin HTTP path for user creation if one is not already sufficient.
5. Repoint `reliquary-user` at the API. Keep a direct-bucket path only for
   first-admin bootstrap, refusing to run against a non-empty store.
6. Confirm the regression tests still fail — they describe `UserStore`, which is
   unchanged — and add a test asserting the CLI no longer writes the object
   directly outside bootstrap.
7. Document the CLI's new requirements in `docs/deployment.md`.

## Acceptance Criteria

- ~~`UserStore` accepts an interface, and a fake exercises the full persist path
  in tests.~~ **Met.**
- ~~The lost-update scenario is covered by a test that fails against today's
  behaviour.~~ **Met**, in both directions.
- Both directions pass once the fix lands — the stale-writer case
  (`TestUserStore_StaleWriterRevertsCompletedWrite`) must not be overlooked, as a
  fix aimed only at the CLI's write window would leave it failing.
- `reliquary-user` performs no direct write to the user object outside
  first-admin bootstrap.
- Bootstrapping a first admin still works with no server running.
- Bootstrap refuses to run against a non-empty user store.
- OIDC and proxy auth behaviour unchanged.

## Notes

The file index (`backend/storage/file_index.go`) and checksum index
(`backend/storage/checksum_index.go`) share this design: a JSON document in the
bucket, held in memory, rewritten whole, guarded by an in-process lock. Both are
per-user rather than global, which narrows contention considerably, and neither
has a second writer today. Option A would fix all three. Option B fixes only
this one, and leaves the pattern in place elsewhere.
