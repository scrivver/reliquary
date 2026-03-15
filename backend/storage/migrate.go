package storage

import (
	"context"
	"log/slog"
	"strings"
)

// MigrateLegacyPrefix moves all objects from the old "user/" prefix to the
// given admin username's namespace. This is a one-time migration for upgrades
// from the single-user version.
func MigrateLegacyPrefix(ctx context.Context, client *Client, adminUsername string) error {
	// Check if old prefix has any objects.
	oldObjects, err := client.ListObjects(ctx, "user/")
	if err != nil {
		return err
	}

	if len(oldObjects) == 0 {
		return nil
	}

	slog.Info("migrating legacy files", "count", len(oldObjects), "from", "user/", "to", adminUsername+"/")

	migrated := 0
	for _, obj := range oldObjects {
		newKey := strings.Replace(obj.Key, "user/", adminUsername+"/", 1)

		if err := client.MoveObject(ctx, obj.Key, newKey); err != nil {
			slog.Error("migration: failed to move object", "from", obj.Key, "to", newKey, "error", err)
			continue
		}

		migrated++
	}

	// Also migrate the old checksums.json if it exists.
	oldChecksumKey := "user/checksums.json"
	newChecksumKey := adminUsername + "/checksums.json"
	if err := client.MoveObject(ctx, oldChecksumKey, newChecksumKey); err != nil {
		slog.Debug("no legacy checksums.json to migrate")
	}

	slog.Info("legacy migration complete", "migrated", migrated, "total", len(oldObjects))
	return nil
}
