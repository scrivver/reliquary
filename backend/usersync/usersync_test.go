package usersync

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
)

type fakeReloader struct {
	mu      sync.Mutex
	etag    string
	reloads int
	err     error
}

func (f *fakeReloader) CurrentETag() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.etag
}

func (f *fakeReloader) Reload(ctx context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reloads++
	return f.err
}

func (f *fakeReloader) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.reloads
}

func body(t *testing.T, c Change) []byte {
	t.Helper()
	b, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestHandle_ReloadsOnChangeFromAnotherWriter(t *testing.T) {
	store := &fakeReloader{etag: "etag-1"}
	sub := NewSubscriber("", "exchange", "api-self", store)

	sub.handle(context.Background(), body(t, Change{ETag: "etag-2", Origin: "api-other"}))

	if store.count() != 1 {
		t.Fatalf("expected a reload, got %d", store.count())
	}
}

// A fanout delivers to every bound queue including the publisher's, so a
// replica must ignore the echo of its own write.
func TestHandle_IgnoresOwnEcho(t *testing.T) {
	store := &fakeReloader{etag: "etag-1"}
	sub := NewSubscriber("", "exchange", "api-self", store)

	sub.handle(context.Background(), body(t, Change{ETag: "etag-2", Origin: "api-self"}))

	if store.count() != 0 {
		t.Fatalf("a replica reloaded on its own publish (%d reloads)", store.count())
	}
}

func TestHandle_SkipsWhenAlreadyOnVersion(t *testing.T) {
	store := &fakeReloader{etag: "etag-2"}
	sub := NewSubscriber("", "exchange", "api-self", store)

	sub.handle(context.Background(), body(t, Change{ETag: "etag-2", Origin: "api-other"}))

	if store.count() != 0 {
		t.Fatalf("reloaded despite already being on the announced version (%d reloads)", store.count())
	}
}

// An empty ETag carries no version information, so it must still trigger a
// reload rather than being mistaken for a match against an unloaded store.
func TestHandle_ReloadsOnEmptyETag(t *testing.T) {
	store := &fakeReloader{etag: ""}
	sub := NewSubscriber("", "exchange", "api-self", store)

	sub.handle(context.Background(), body(t, Change{ETag: "", Origin: "api-other"}))

	if store.count() != 1 {
		t.Fatalf("expected a reload, got %d", store.count())
	}
}

func TestHandle_MalformedMessageIsDiscarded(t *testing.T) {
	store := &fakeReloader{}
	sub := NewSubscriber("", "exchange", "api-self", store)

	sub.handle(context.Background(), []byte("not json"))

	if store.count() != 0 {
		t.Fatalf("malformed message triggered %d reloads", store.count())
	}
}

func TestNewOrigin_IsDistinct(t *testing.T) {
	seen := make(map[string]bool)
	for i := 0; i < 100; i++ {
		origin := NewOrigin("api")
		if !strings.HasPrefix(origin, "api-") {
			t.Fatalf("origin %q lost its prefix", origin)
		}
		if seen[origin] {
			t.Fatalf("duplicate origin %q: replicas would ignore each other's changes", origin)
		}
		seen[origin] = true
	}
}

func TestChangePayloadCarriesNoUserData(t *testing.T) {
	raw, err := Change{ETag: "etag-1", Origin: "api-1", At: "2026-09-01T00:00:00Z"}.marshal()
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	for key := range fields {
		switch key {
		case "etag", "origin", "at":
		default:
			t.Fatalf("unexpected field %q: this message must never carry account state", key)
		}
	}
}
