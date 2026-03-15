package storage

import (
	"context"
	"fmt"
	"mime"
	"path"
	"strings"
)

type UserStats struct {
	TotalSize    int64          `json:"total_size"`
	FileCount    int            `json:"file_count"`
	ArchiveCount int            `json:"archive_count"`
	ArchiveSize  int64          `json:"archive_size"`
	ByType       map[string]int `json:"by_type"`
	ByMonth      map[string]int `json:"by_month"`
}

// ComputeUserStats calculates storage analytics for a user.
func (c *Client) ComputeUserStats(ctx context.Context, username string) (UserStats, error) {
	stats := UserStats{
		ByType:  make(map[string]int),
		ByMonth: make(map[string]int),
	}

	// Active files.
	filesPrefix := fmt.Sprintf("%s/files/", username)
	files, err := c.ListObjects(ctx, filesPrefix)
	if err != nil {
		return stats, err
	}

	for _, obj := range files {
		stats.FileCount++
		stats.TotalSize += obj.Size

		ct := obj.ContentType
		if ct == "" {
			ct = mime.TypeByExtension(path.Ext(obj.Key))
		}
		if ct == "" {
			ct = "application/octet-stream"
		}
		// Group by major type (image, video, audio, etc.)
		major := strings.SplitN(ct, "/", 2)[0]
		stats.ByType[major]++

		// Group by month from the key path: {user}/files/YYYY/MM/...
		if month := extractMonth(obj.Key, filesPrefix); month != "" {
			stats.ByMonth[month]++
		}
	}

	// Archived files.
	archivePrefix := fmt.Sprintf("%s/archive/", username)
	archived, err := c.ListObjects(ctx, archivePrefix)
	if err != nil {
		return stats, err
	}

	for _, obj := range archived {
		stats.ArchiveCount++
		stats.ArchiveSize += obj.Size
	}

	return stats, nil
}

// extractMonth extracts "YYYY/MM" from a key like "{prefix}YYYY/MM/filename".
func extractMonth(key, prefix string) string {
	rest := strings.TrimPrefix(key, prefix)
	parts := strings.SplitN(rest, "/", 3)
	if len(parts) >= 2 {
		return parts[0] + "/" + parts[1]
	}
	return ""
}
