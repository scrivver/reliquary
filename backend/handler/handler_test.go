package handler

import "testing"

func TestSanitizeFilename(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"photo.jpg", "photo.jpg"},
		{"../../../etc/passwd", "passwd"},
		{"/home/user/docs/file.pdf", "file.pdf"},
		{"sub/dir/image.png", "image.png"},
		{"simple", "simple"},
	}

	for _, tt := range tests {
		got := sanitizeFilename(tt.input)
		if got != tt.want {
			t.Errorf("sanitizeFilename(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestIsImageContentType(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"image/jpeg", true},
		{"image/png", true},
		{"image/gif", true},
		{"video/mp4", false},
		{"application/pdf", false},
		{"", false},
	}

	for _, tt := range tests {
		got := isImageContentType(tt.input)
		if got != tt.want {
			t.Errorf("isImageContentType(%q) = %v, want %v", tt.input, got, tt.want)
		}
	}
}

func TestIsVideoContentType(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"video/mp4", true},
		{"video/webm", true},
		{"image/jpeg", false},
		{"application/octet-stream", false},
		{"", false},
	}

	for _, tt := range tests {
		got := isVideoContentType(tt.input)
		if got != tt.want {
			t.Errorf("isVideoContentType(%q) = %v, want %v", tt.input, got, tt.want)
		}
	}
}
