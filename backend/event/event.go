package event

import "context"

const (
	Create       = "create"
	Delete       = "delete"
	StorageS3    = "s3"
	DefaultQueue = "engram.ingest"
)

// FileEvent is the canonical Engram ingestion message.
type FileEvent struct {
	Event       string `json:"event"`
	FilePath    string `json:"file_path"`
	Filename    string `json:"filename"`
	Size        int64  `json:"size"`
	Hash        string `json:"hash"`
	Mtime       string `json:"mtime"`
	DeviceName  string `json:"device_name"`
	StorageType string `json:"storage_type"`
	OldFilePath string `json:"old_file_path,omitempty"`
}

// Emitter publishes file mutations to Engram.
type Emitter interface {
	Emit(ctx context.Context, event FileEvent) error
	Close() error
}

type DisabledEmitter struct{}

func (DisabledEmitter) Emit(context.Context, FileEvent) error { return nil }
func (DisabledEmitter) Close() error                          { return nil }
