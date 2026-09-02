// Package usersync carries user-store invalidation hints between API replicas.
//
// It is deliberately separate from package event, which encodes the canonical
// Engram file-event contract. These messages are internal control traffic: they
// are not a published contract, they carry no file data, and they must never be
// routed anywhere Engram consumes.
//
// The channel is best-effort by design. Correctness comes from the
// compare-and-swap writes in package auth; this only shortens the window in
// which a replica serves a stale view, from one periodic reload down to a round
// trip. Nothing here may fail a mutation, and the periodic reload remains the
// backstop for every case a message is lost.
package usersync

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"
)

// Change announces that the persisted user store advanced to a new version.
//
// The payload is deliberately minimal: a hint to re-read, never account state.
// Keeping password hashes off the message bus is worth the extra round trip,
// and it keeps the bucket the single source of truth.
type Change struct {
	// ETag identifies the version just written. A receiver already on this
	// version can skip the reload entirely.
	ETag string `json:"etag"`
	// Origin is the publishing process, so a replica ignores the echo of its
	// own publish — a fanout delivers to every bound queue, including the
	// publisher's.
	Origin string `json:"origin"`
	At     string `json:"at"`
}

// NewOrigin returns a per-process identifier used to recognise our own
// messages.
func NewOrigin(prefix string) string {
	buf := make([]byte, 6)
	if _, err := rand.Read(buf); err != nil {
		// A collision only costs a redundant reload, so a degraded identifier
		// is better than failing to start.
		return fmt.Sprintf("%s-%d", prefix, time.Now().UnixNano())
	}
	return prefix + "-" + hex.EncodeToString(buf)
}

func (c Change) marshal() ([]byte, error) {
	return json.Marshal(c)
}

// Reloader is the side of auth.UserStore this package drives.
type Reloader interface {
	// CurrentETag reports the version the store currently holds, so an
	// already-applied change can be skipped without a storage round trip.
	CurrentETag() string
	// Reload re-reads the store from object storage.
	Reload(ctx context.Context) error
}
