package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"sync"
)

// ChecksumIndex maintains per-user checksum → object key mappings stored in MinIO.
type ChecksumIndex struct {
	client *Client
	mu     sync.Mutex
	users  map[string]map[string]string // username → (checksum → key)
}

func NewChecksumIndex(client *Client) *ChecksumIndex {
	return &ChecksumIndex{
		client: client,
		users:  make(map[string]map[string]string),
	}
}

func indexKey(username string) string {
	return fmt.Sprintf("%s/checksums.json", username)
}

// LoadUser loads the checksum index for a specific user. Safe to call multiple times.
func (ci *ChecksumIndex) LoadUser(ctx context.Context, username string) error {
	ci.mu.Lock()
	defer ci.mu.Unlock()

	if _, loaded := ci.users[username]; loaded {
		return nil
	}

	index := make(map[string]string)

	obj, err := ci.client.GetObject(ctx, indexKey(username))
	if err != nil {
		ci.users[username] = index
		return nil
	}
	defer obj.Close()

	data, err := io.ReadAll(obj)
	if err != nil || len(data) == 0 {
		ci.users[username] = index
		return nil
	}

	if err := json.Unmarshal(data, &index); err != nil {
		slog.Warn("failed to parse checksum index", "user", username, "error", err)
		index = make(map[string]string)
	}

	ci.users[username] = index
	slog.Info("checksum index loaded", "user", username, "entries", len(index))
	return nil
}

// Lookup returns the existing key for a checksum within a user's namespace.
func (ci *ChecksumIndex) Lookup(username, checksum string) string {
	ci.mu.Lock()
	defer ci.mu.Unlock()
	if idx, ok := ci.users[username]; ok {
		return idx[checksum]
	}
	return ""
}

// Add registers a checksum → key mapping for a user and persists.
func (ci *ChecksumIndex) Add(ctx context.Context, username, checksum, key string) error {
	ci.mu.Lock()
	if ci.users[username] == nil {
		ci.users[username] = make(map[string]string)
	}
	ci.users[username][checksum] = key
	ci.mu.Unlock()

	return ci.persist(ctx, username)
}

// RemoveByKey removes the entry with the given key value for a user and persists.
func (ci *ChecksumIndex) RemoveByKey(ctx context.Context, username, key string) error {
	ci.mu.Lock()
	if idx, ok := ci.users[username]; ok {
		for cs, k := range idx {
			if k == key {
				delete(idx, cs)
				break
			}
		}
	}
	ci.mu.Unlock()

	return ci.persist(ctx, username)
}

func (ci *ChecksumIndex) persist(ctx context.Context, username string) error {
	ci.mu.Lock()
	idx := ci.users[username]
	data, err := json.Marshal(idx)
	ci.mu.Unlock()

	if err != nil {
		return err
	}

	return ci.client.PutObject(ctx, indexKey(username), bytes.NewReader(data), int64(len(data)), "application/json", nil)
}
