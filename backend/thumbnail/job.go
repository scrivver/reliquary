package thumbnail

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

const (
	JobVersion   = 1
	DefaultQueue = "reliquary.thumbnail"
	DefaultDead  = "reliquary.thumbnail.dead"
)

type Job struct {
	Version     int    `json:"version"`
	FileKey     string `json:"file_key"`
	ContentType string `json:"content_type"`
	Checksum    string `json:"checksum"`
}

func (j Job) Validate() error {
	if j.Version != JobVersion {
		return fmt.Errorf("unsupported thumbnail job version %d", j.Version)
	}
	if !strings.HasPrefix(j.FileKey, "files/") ||
		strings.TrimPrefix(j.FileKey, "files/") == "" {
		return fmt.Errorf("invalid file key %q", j.FileKey)
	}
	if j.ContentType == "" {
		return errors.New("content_type is required")
	}
	if j.Checksum == "" {
		return errors.New("checksum is required")
	}
	return nil
}

func SupportedContentType(contentType string) bool {
	return strings.HasPrefix(contentType, "image/") ||
		strings.HasPrefix(contentType, "video/") ||
		contentType == "application/pdf"
}

type Publisher interface {
	Publish(ctx context.Context, job Job) error
	Close() error
}

type Processor interface {
	Process(ctx context.Context, job Job) error
}

type discardError struct {
	err error
}

func (e discardError) Error() string { return e.err.Error() }
func (e discardError) Unwrap() error { return e.err }

func Discard(err error) error {
	if err == nil {
		return nil
	}
	return discardError{err: err}
}

func IsDiscard(err error) bool {
	var target discardError
	return errors.As(err, &target)
}
