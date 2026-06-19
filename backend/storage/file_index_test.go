package storage

import (
	"bytes"
	"context"
	"io"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"
)

type fakeIndexObjectStore struct {
	objects map[string][]byte
	stats   map[string]minio.ObjectInfo
	list    []minio.ObjectInfo
}

func (s *fakeIndexObjectStore) GetObject(_ context.Context, key string) (io.ReadCloser, error) {
	data, ok := s.objects[key]
	if !ok {
		return nil, minio.ErrorResponse{Code: "NoSuchKey"}
	}
	return io.NopCloser(bytes.NewReader(data)), nil
}

func (s *fakeIndexObjectStore) PutObject(_ context.Context, key string, reader io.Reader, _ int64, _ string, _ map[string]string) error {
	data, err := io.ReadAll(reader)
	if err != nil {
		return err
	}
	s.objects[key] = data
	return nil
}

func (s *fakeIndexObjectStore) DeleteObject(_ context.Context, key string) error {
	if _, ok := s.objects[key]; !ok {
		return minio.ErrorResponse{Code: "NoSuchKey"}
	}
	delete(s.objects, key)
	return nil
}

func (s *fakeIndexObjectStore) ListObjects(context.Context, string) ([]minio.ObjectInfo, error) {
	return s.list, nil
}

func (s *fakeIndexObjectStore) StatObject(_ context.Context, key string) (minio.ObjectInfo, error) {
	stat, ok := s.stats[key]
	if !ok {
		return minio.ObjectInfo{}, minio.ErrorResponse{Code: "NoSuchKey"}
	}
	return stat, nil
}

func TestFileIndexUpsertCreatesAndReplacesManifestEntries(t *testing.T) {
	store := &fakeIndexObjectStore{objects: make(map[string][]byte)}
	index := &FileIndex{store: store}
	ctx := context.Background()

	first := FileIndexItem{
		Key:          "files/alice/2026/06/report.txt",
		Size:         10,
		ContentType:  "text/plain",
		LastModified: time.Date(2026, 6, 19, 10, 0, 0, 0, time.UTC),
		Checksum:     "one",
	}
	if err := index.Upsert(ctx, "alice", first); err != nil {
		t.Fatal(err)
	}

	first.Size = 20
	first.Checksum = "two"
	if err := index.Upsert(ctx, "alice", first); err != nil {
		t.Fatal(err)
	}

	manifest, err := index.Load(ctx, "alice")
	if err != nil {
		t.Fatal(err)
	}
	if len(manifest.Files) != 1 {
		t.Fatalf("files=%d, want 1", len(manifest.Files))
	}
	if manifest.Files[0].Size != 20 || manifest.Files[0].Checksum != "two" {
		t.Fatalf("manifest entry was not replaced: %+v", manifest.Files[0])
	}
}

func TestFileIndexRemoveDeletesManifestEntry(t *testing.T) {
	store := &fakeIndexObjectStore{objects: make(map[string][]byte)}
	index := &FileIndex{store: store}
	ctx := context.Background()

	items := []FileIndexItem{
		{Key: "files/alice/2026/06/a.txt", ContentType: "text/plain"},
		{Key: "files/alice/2026/06/b.txt", ContentType: "text/plain"},
	}
	for _, item := range items {
		if err := index.Upsert(ctx, "alice", item); err != nil {
			t.Fatal(err)
		}
	}

	if err := index.Remove(ctx, "alice", items[0].Key); err != nil {
		t.Fatal(err)
	}

	manifest, err := index.Load(ctx, "alice")
	if err != nil {
		t.Fatal(err)
	}
	if len(manifest.Files) != 1 || manifest.Files[0].Key != items[1].Key {
		t.Fatalf("unexpected manifest files: %+v", manifest.Files)
	}
}

func TestFileIndexEnsureCreatesEmptyManifest(t *testing.T) {
	store := &fakeIndexObjectStore{objects: make(map[string][]byte)}
	index := &FileIndex{store: store}
	ctx := context.Background()

	if err := index.Ensure(ctx, "alice"); err != nil {
		t.Fatal(err)
	}

	manifest, err := index.Load(ctx, "alice")
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Version != 1 || len(manifest.Files) != 0 {
		t.Fatalf("unexpected manifest: %+v", manifest)
	}
}

func TestComputeStatsFromManifest(t *testing.T) {
	manifest := FileManifest{Files: []FileIndexItem{
		{
			Key:         "files/alice/2026/06/photo.jpg",
			Size:        10,
			ContentType: "image/jpeg",
		},
		{
			Key:         "files/alice/2026/07/video.mp4",
			Size:        20,
			ContentType: "video/mp4",
		},
	}}

	stats := ComputeStatsFromManifest(manifest)
	if stats.FileCount != 2 || stats.TotalSize != 30 {
		t.Fatalf("unexpected totals: %+v", stats)
	}
	if stats.ByType["image"] != 1 || stats.ByType["video"] != 1 {
		t.Fatalf("unexpected type counts: %+v", stats.ByType)
	}
	if stats.ByMonth["2026/06"] != 1 || stats.ByMonth["2026/07"] != 1 {
		t.Fatalf("unexpected month counts: %+v", stats.ByMonth)
	}
}
