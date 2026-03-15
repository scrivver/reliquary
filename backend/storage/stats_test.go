package storage

import "testing"

func TestExtractMonth(t *testing.T) {
	tests := []struct {
		key    string
		prefix string
		want   string
	}{
		{"admin/files/2026/03/photo.jpg", "admin/files/", "2026/03"},
		{"alice/files/2025/12/doc.pdf", "alice/files/", "2025/12"},
		{"admin/files/photo.jpg", "admin/files/", ""},
		{"", "admin/files/", ""},
	}

	for _, tt := range tests {
		got := extractMonth(tt.key, tt.prefix)
		if got != tt.want {
			t.Errorf("extractMonth(%q, %q) = %q, want %q", tt.key, tt.prefix, got, tt.want)
		}
	}
}
