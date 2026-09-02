package storage

import (
	"net/http"
	"testing"

	"github.com/minio/minio-go/v7"
)

func TestNormalizeETag(t *testing.T) {
	cases := map[string]string{
		`"abc123"`: "abc123",
		"abc123":   "abc123",
		`""`:       "",
		"":         "",
	}
	for in, want := range cases {
		if got := normalizeETag(in); got != want {
			t.Errorf("normalizeETag(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestIsPreconditionFailed(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{
			"minio code",
			minio.ErrorResponse{Code: "PreconditionFailed", StatusCode: http.StatusPreconditionFailed},
			true,
		},
		{
			// A backend that returns 412 under a different code string still
			// means the same thing.
			"status only",
			minio.ErrorResponse{Code: "SomethingElse", StatusCode: http.StatusPreconditionFailed},
			true,
		},
		{
			"unrelated error",
			minio.ErrorResponse{Code: "NoSuchKey", StatusCode: http.StatusNotFound},
			false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isPreconditionFailed(tt.err); got != tt.want {
				t.Errorf("isPreconditionFailed(%v) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}
