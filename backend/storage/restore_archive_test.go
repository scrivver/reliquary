package storage

import (
	"context"
	"errors"
	"testing"

	"github.com/minio/minio-go/v7"
)

type fakeArchiveStore struct {
	objects   map[string]minio.ObjectInfo
	moves     [][2]string
	statError error
}

func (s *fakeArchiveStore) ListObjects(_ context.Context, prefix string) ([]minio.ObjectInfo, error) {
	var objects []minio.ObjectInfo
	for key, obj := range s.objects {
		if len(key) >= len(prefix) && key[:len(prefix)] == prefix {
			objects = append(objects, obj)
		}
	}
	return objects, nil
}

func (s *fakeArchiveStore) StatObject(_ context.Context, key string) (minio.ObjectInfo, error) {
	if obj, ok := s.objects[key]; ok {
		return obj, nil
	}
	if s.statError != nil {
		return minio.ObjectInfo{}, s.statError
	}
	return minio.ObjectInfo{}, minio.ErrorResponse{Code: "NoSuchKey"}
}

func (s *fakeArchiveStore) MoveObject(_ context.Context, srcKey, dstKey string) error {
	obj, ok := s.objects[srcKey]
	if !ok {
		return errors.New("source missing")
	}
	delete(s.objects, srcKey)
	obj.Key = dstKey
	s.objects[dstKey] = obj
	s.moves = append(s.moves, [2]string{srcKey, dstKey})
	return nil
}

func TestRestoreArchivedObjectsDryRun(t *testing.T) {
	store := &fakeArchiveStore{objects: map[string]minio.ObjectInfo{
		"archive/alice/2026/01/report.pdf": {
			Key: "archive/alice/2026/01/report.pdf",
		},
		"archive-thumbs/alice/2026/01/report.pdf": {
			Key: "archive-thumbs/alice/2026/01/report.pdf",
		},
	}}

	report, err := RestoreArchivedObjects(context.Background(), store, false)
	if err != nil {
		t.Fatal(err)
	}
	if report.Planned != 2 || report.Restored != 0 || len(store.moves) != 0 {
		t.Fatalf("unexpected report: %+v moves=%v", report, store.moves)
	}
}

func TestRestoreArchivedObjectsMovesFilesAndThumbnails(t *testing.T) {
	store := &fakeArchiveStore{objects: map[string]minio.ObjectInfo{
		"archive/alice/2026/01/report.pdf": {
			Key:          "archive/alice/2026/01/report.pdf",
			UserMetadata: map[string]string{"Checksum": "abc123"},
		},
		"archive-thumbs/alice/2026/01/report.pdf": {
			Key: "archive-thumbs/alice/2026/01/report.pdf",
		},
	}}
	report, err := RestoreArchivedObjects(context.Background(), store, true)
	if err != nil {
		t.Fatal(err)
	}
	if report.Restored != 2 || report.Failed != 0 {
		t.Fatalf("unexpected report: %+v", report)
	}
	if _, ok := store.objects["files/alice/2026/01/report.pdf"]; !ok {
		t.Fatal("active file was not restored")
	}
	if _, ok := store.objects["thumbs/alice/2026/01/report.pdf"]; !ok {
		t.Fatal("thumbnail was not restored")
	}
}

func TestRestoreArchivedObjectsSkipsConflicts(t *testing.T) {
	store := &fakeArchiveStore{objects: map[string]minio.ObjectInfo{
		"archive/alice/report.pdf": {Key: "archive/alice/report.pdf"},
		"files/alice/report.pdf":   {Key: "files/alice/report.pdf"},
	}}

	report, err := RestoreArchivedObjects(context.Background(), store, true)
	if err != nil {
		t.Fatal(err)
	}
	if report.Conflicts != 1 || report.Restored != 0 || len(store.moves) != 0 {
		t.Fatalf("unexpected report: %+v moves=%v", report, store.moves)
	}
	if len(report.ConflictKeys) != 1 ||
		report.ConflictKeys[0] != "archive/alice/report.pdf -> files/alice/report.pdf" {
		t.Fatalf("unexpected conflicts: %v", report.ConflictKeys)
	}
}

func TestUsernameFromActiveKey(t *testing.T) {
	username, ok := usernameFromActiveKey("files/alice/2026/01/report.pdf")
	if !ok || username != "alice" {
		t.Fatalf("got username=%q ok=%v", username, ok)
	}
}
