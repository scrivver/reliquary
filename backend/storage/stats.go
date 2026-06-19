package storage

import "strings"

type UserStats struct {
	TotalSize int64          `json:"total_size"`
	FileCount int            `json:"file_count"`
	ByType    map[string]int `json:"by_type"`
	ByMonth   map[string]int `json:"by_month"`
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
