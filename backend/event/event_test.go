package event

import (
	"encoding/json"
	"testing"
)

func TestFileEventMatchesCanonicalCreateContract(t *testing.T) {
	event := FileEvent{
		Event:       Create,
		FilePath:    "files/alice/2026/06/report.pdf",
		Filename:    "report.pdf",
		Size:        204800,
		Hash:        "sha256:abcdef123456",
		Mtime:       "2026-06-15T12:00:00Z",
		DeviceName:  "reliquary",
		StorageType: StorageS3,
	}

	got, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}

	const want = `{"event":"create","file_path":"files/alice/2026/06/report.pdf","filename":"report.pdf","size":204800,"hash":"sha256:abcdef123456","mtime":"2026-06-15T12:00:00Z","device_name":"reliquary","storage_type":"s3"}`
	if string(got) != want {
		t.Fatalf("canonical event mismatch:\ngot:  %s\nwant: %s", got, want)
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
