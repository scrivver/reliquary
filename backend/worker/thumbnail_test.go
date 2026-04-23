package worker

import "testing"

func TestFileToThumbKey(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"files/admin/2026/03/photo.jpg", "thumbs/admin/2026/03/photo.jpg"},
		{"files/alice/2026/01/video.mp4", "thumbs/alice/2026/01/video.mp4"},
		{"files/user/2025/12/doc.pdf", "thumbs/user/2025/12/doc.pdf"},
		{"no-files-prefix/2026/03/photo.jpg", ""},
		{"", ""},
	}

	for _, tt := range tests {
		got := fileToThumbKey(tt.input)
		if got != tt.want {
			t.Errorf("fileToThumbKey(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}
