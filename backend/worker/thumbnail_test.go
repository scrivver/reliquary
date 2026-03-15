package worker

import "testing"

func TestFileToThumbKey(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"admin/files/2026/03/photo.jpg", "admin/thumbs/2026/03/photo.jpg"},
		{"alice/files/2026/01/video.mp4", "alice/thumbs/2026/01/video.mp4"},
		{"user/files/2025/12/doc.pdf", "user/thumbs/2025/12/doc.pdf"},
		{"no-files-segment/2026/03/photo.jpg", ""},
		{"", ""},
	}

	for _, tt := range tests {
		got := fileToThumbKey(tt.input)
		if got != tt.want {
			t.Errorf("fileToThumbKey(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}
