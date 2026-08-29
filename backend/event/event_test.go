package event

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestFileEventMatchesCanonicalCreateContract(t *testing.T) {
	event := FileEvent{
		Event:       Create,
		FilePath:    "files/alice/2026/07/docs/myfile.pdf",
		Filename:    "docs/myfile.pdf",
		Size:        204800,
		Hash:        "sha256:abcdef123456",
		Mtime:       "2026-07-12T12:00:00Z",
		DeviceName:  "reliquary",
		StorageType: StorageS3,
	}

	got, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}

	const want = `{"event":"create","file_path":"files/alice/2026/07/docs/myfile.pdf","filename":"docs/myfile.pdf","size":204800,"hash":"sha256:abcdef123456","mtime":"2026-07-12T12:00:00Z","device_name":"reliquary","storage_type":"s3"}`
	if string(got) != want {
		t.Fatalf("canonical event mismatch:\ngot:  %s\nwant: %s", got, want)
	}
}

func TestCreateFixtureUsesDisplayPathContract(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("..", "..", "contracts", "file-events", "create.json"))
	if err != nil {
		t.Fatal(err)
	}

	var event FileEvent
	if err := json.Unmarshal(body, &event); err != nil {
		t.Fatal(err)
	}
	if event.Filename != "docs/myfile.pdf" {
		t.Fatalf("filename=%q, want display path docs/myfile.pdf", event.Filename)
	}
	if event.FilePath != "files/alice/2026/07/docs/myfile.pdf" {
		t.Fatalf("file_path=%q, want storage identity", event.FilePath)
	}
}

func TestFileEventDeleteIncludesCanonicalEmptyFields(t *testing.T) {
	event := FileEvent{
		Event:       Delete,
		FilePath:    "files/alice/report.pdf",
		Filename:    "report.pdf",
		DeviceName:  "reliquary",
		StorageType: StorageS3,
	}

	got, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}

	const want = `{"event":"delete","file_path":"files/alice/report.pdf","filename":"report.pdf","size":0,"hash":"","mtime":"","device_name":"reliquary","storage_type":"s3"}`
	if string(got) != want {
		t.Fatalf("canonical event mismatch:\ngot:  %s\nwant: %s", got, want)
	}
}
