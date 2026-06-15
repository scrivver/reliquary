package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/minio/minio-go/v7"
)

type archiveStore interface {
	ListObjects(ctx context.Context, prefix string) ([]minio.ObjectInfo, error)
	StatObject(ctx context.Context, key string) (minio.ObjectInfo, error)
	MoveObject(ctx context.Context, srcKey, dstKey string) error
}

type RestoreReport struct {
	Planned      int
	Restored     int
	Conflicts    int
	Failed       int
	ConflictKeys []string
	FailedKeys   []string
}

// RestoreArchivedObjects moves archived files and thumbnails back to their
// active prefixes. It never overwrites an existing destination.
func RestoreArchivedObjects(
	ctx context.Context,
	store archiveStore,
	apply bool,
) (RestoreReport, error) {
	report, err := restorePrefix(ctx, store, "archive/", "files/", apply)
	if err != nil {
		return report, err
	}

	thumbnailReport, err := restorePrefix(
		ctx,
		store,
		"archive-thumbs/",
		"thumbs/",
		apply,
	)
	report.Planned += thumbnailReport.Planned
	report.Restored += thumbnailReport.Restored
	report.Conflicts += thumbnailReport.Conflicts
	report.Failed += thumbnailReport.Failed
	report.ConflictKeys = append(report.ConflictKeys, thumbnailReport.ConflictKeys...)
	report.FailedKeys = append(report.FailedKeys, thumbnailReport.FailedKeys...)
	return report, err
}

func restorePrefix(
	ctx context.Context,
	store archiveStore,
	sourcePrefix string,
	destinationPrefix string,
	apply bool,
) (RestoreReport, error) {
	var report RestoreReport
	objects, err := store.ListObjects(ctx, sourcePrefix)
	if err != nil {
		return report, fmt.Errorf("list %q: %w", sourcePrefix, err)
	}

	for _, obj := range objects {
		destination := destinationPrefix + strings.TrimPrefix(obj.Key, sourcePrefix)
		if _, err := store.StatObject(ctx, destination); err == nil {
			report.Conflicts++
			report.ConflictKeys = append(report.ConflictKeys, obj.Key+" -> "+destination)
			continue
		} else if !IsObjectNotFound(err) {
			report.Failed++
			report.FailedKeys = append(report.FailedKeys, obj.Key+" -> "+destination)
			continue
		}

		report.Planned++
		if !apply {
			continue
		}
		if err := store.MoveObject(ctx, obj.Key, destination); err != nil {
			report.Failed++
			report.FailedKeys = append(report.FailedKeys, obj.Key+" -> "+destination)
			continue
		}
		report.Restored++
	}

	return report, nil
}

// RebuildChecksumIndexes recreates per-user checksum indexes from active files.
func RebuildChecksumIndexes(ctx context.Context, client *Client) error {
	objects, err := client.ListObjects(ctx, "files/")
	if err != nil {
		return fmt.Errorf("list active files: %w", err)
	}

	indexes := make(map[string]map[string]string)
	for _, obj := range objects {
		username, ok := usernameFromActiveKey(obj.Key)
		if !ok {
			continue
		}
		stat, err := client.StatObject(ctx, obj.Key)
		if err != nil {
			return fmt.Errorf("stat active object %q: %w", obj.Key, err)
		}
		if indexes[username] == nil {
			indexes[username] = make(map[string]string)
		}
		checksum := stat.UserMetadata["Checksum"]
		if checksum == "" {
			continue
		}
		indexes[username][checksum] = obj.Key
	}

	for username, index := range indexes {
		data, err := json.Marshal(index)
		if err != nil {
			return fmt.Errorf("marshal checksum index for %q: %w", username, err)
		}
		if err := client.PutObject(
			ctx,
			indexKey(username),
			bytes.NewReader(data),
			int64(len(data)),
			"application/json",
			nil,
		); err != nil {
			return fmt.Errorf("write checksum index for %q: %w", username, err)
		}
	}

	return nil
}

func usernameFromActiveKey(key string) (string, bool) {
	rest := strings.TrimPrefix(key, "files/")
	if rest == key {
		return "", false
	}
	username, _, ok := strings.Cut(rest, "/")
	return username, ok && username != ""
}
