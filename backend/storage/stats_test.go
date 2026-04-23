package storage

import "testing"

func TestExtractMonth(t *testing.T) {
	tests := []struct {
		key    string
		prefix string
		want   string
	}{
		{"files/admin/2026/03/photo.jpg", "files/admin/", "2026/03"},
		{"files/alice/2025/12/doc.pdf", "files/alice/", "2025/12"},
		{"files/admin/photo.jpg", "files/admin/", ""},
		{"", "files/admin/", ""},
	}

	for _, tt := range tests {
		got := extractMonth(tt.key, tt.prefix)
		if got != tt.want {
			t.Errorf("extractMonth(%q, %q) = %q, want %q", tt.key, tt.prefix, got, tt.want)
		}
	}
}
