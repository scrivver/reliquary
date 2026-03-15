package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"sync"
)

const checksumIndexKey = "user/checksums.json"

// ChecksumIndex maintains a checksum → object key mapping stored in MinIO.
type ChecksumIndex struct {
	client *Client
	mu     sync.Mutex
	index  map[string]string // checksum → key
	loaded bool
}

func NewChecksumIndex(client *Client) *ChecksumIndex {
	return &ChecksumIndex{
		client: client,
		index:  make(map[string]string),
	}
}

// Load reads the index from MinIO. Safe to call multiple times; only loads once.
func (ci *ChecksumIndex) Load(ctx context.Context) error {
	ci.mu.Lock()
	defer ci.mu.Unlock()

	if ci.loaded {
		return nil
	}

	obj, err := ci.client.GetObject(ctx, checksumIndexKey)
	if err != nil {
		// Index doesn't exist yet; start empty.
		ci.loaded = true
		slog.Info("checksum index not found, starting empty")
		return nil
	}
	defer obj.Close()

	data, err := io.ReadAll(obj)
	if err != nil || len(data) == 0 {
		ci.loaded = true
		return nil
	}

	if err := json.Unmarshal(data, &ci.index); err != nil {
		slog.Warn("failed to parse checksum index, starting empty", "error", err)
		ci.index = make(map[string]string)
	}

	ci.loaded = true
	slog.Info("checksum index loaded", "entries", len(ci.index))
	return nil
}

// Lookup returns the existing key for a checksum, or empty string if not found.
func (ci *ChecksumIndex) Lookup(checksum string) string {
	ci.mu.Lock()
	defer ci.mu.Unlock()
	return ci.index[checksum]
}

// Add registers a checksum → key mapping and persists the index.
func (ci *ChecksumIndex) Add(ctx context.Context, checksum, key string) error {
	ci.mu.Lock()
	ci.index[checksum] = key
	ci.mu.Unlock()

	return ci.persist(ctx)
}

// Remove deletes a checksum entry and persists the index.
func (ci *ChecksumIndex) Remove(ctx context.Context, checksum string) error {
	ci.mu.Lock()
	delete(ci.index, checksum)
	ci.mu.Unlock()

	return ci.persist(ctx)
}

// RemoveByKey removes the entry with the given key value and persists.
func (ci *ChecksumIndex) RemoveByKey(ctx context.Context, key string) error {
	ci.mu.Lock()
	for cs, k := range ci.index {
		if k == key {
			delete(ci.index, cs)
			break
		}
	}
	ci.mu.Unlock()

	return ci.persist(ctx)
}

func (ci *ChecksumIndex) persist(ctx context.Context) error {
	ci.mu.Lock()
	data, err := json.Marshal(ci.index)
	ci.mu.Unlock()

	if err != nil {
		return err
	}

	return ci.client.PutObject(ctx, checksumIndexKey, bytes.NewReader(data), int64(len(data)), "application/json", nil)
}
