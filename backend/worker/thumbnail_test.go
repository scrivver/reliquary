package worker

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"io"
	"os/exec"
	"testing"

	"github.com/minio/minio-go/v7"

	"reliquary-be/thumbnail"
)

type memoryThumbnailObject struct {
	data []byte
	info minio.ObjectInfo
}

type memoryThumbnailStore struct {
	objects           map[string]memoryThumbnailObject
	putCount          int
	changeSourceOnPut bool
}

func (s *memoryThumbnailStore) GetObject(_ context.Context, key string) (io.ReadCloser, error) {
	obj, ok := s.objects[key]
	if !ok {
		return nil, minio.ErrorResponse{Code: "NoSuchKey"}
	}
	return io.NopCloser(bytes.NewReader(obj.data)), nil
}

func (s *memoryThumbnailStore) PutObject(
	_ context.Context,
	key string,
	reader io.Reader,
	size int64,
	contentType string,
	userMeta map[string]string,
) error {
	data, err := io.ReadAll(reader)
	if err != nil {
		return err
	}
	s.putCount++
	s.objects[key] = memoryThumbnailObject{
		data: data,
		info: minio.ObjectInfo{
			Key:          key,
			Size:         size,
			ContentType:  contentType,
			UserMetadata: userMeta,
		},
	}
	if s.changeSourceOnPut {
		source := s.objects["files/alice/photo.png"]
		source.info.UserMetadata = map[string]string{"Checksum": "replacement"}
		s.objects["files/alice/photo.png"] = source
	}
	return nil
}

func (s *memoryThumbnailStore) DeleteObject(_ context.Context, key string) error {
	delete(s.objects, key)
	return nil
}

func (s *memoryThumbnailStore) StatObject(_ context.Context, key string) (minio.ObjectInfo, error) {
	obj, ok := s.objects[key]
	if !ok {
		return minio.ObjectInfo{}, minio.ErrorResponse{Code: "NoSuchKey"}
	}
	return obj.info, nil
}

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

func TestThumbnailProcessorIsIdempotentBySourceChecksum(t *testing.T) {
	store := newImageThumbnailStore(t)
	processor := &ThumbnailProcessor{store: store}
	job := thumbnail.Job{
		Version:     thumbnail.JobVersion,
		FileKey:     "files/alice/photo.png",
		ContentType: "image/png",
		Checksum:    "source-checksum",
	}

	if err := processor.Process(context.Background(), job); err != nil {
		t.Fatal(err)
	}
	thumb, ok := store.objects["thumbs/alice/photo.png"]
	if !ok {
		t.Fatal("thumbnail was not stored")
	}
	if metadataValue(thumb.info.UserMetadata, "Source-Checksum") != job.Checksum {
		t.Fatalf("unexpected metadata: %+v", thumb.info.UserMetadata)
	}

	if err := processor.Process(context.Background(), job); err != nil {
		t.Fatal(err)
	}
	if store.putCount != 1 {
		t.Fatalf("thumbnail writes=%d, want 1", store.putCount)
	}
}

func TestThumbnailProcessorDiscardsMissingSource(t *testing.T) {
	store := &memoryThumbnailStore{objects: make(map[string]memoryThumbnailObject)}
	processor := &ThumbnailProcessor{store: store}
	err := processor.Process(context.Background(), thumbnail.Job{
		Version:     thumbnail.JobVersion,
		FileKey:     "files/alice/missing.png",
		ContentType: "image/png",
		Checksum:    "missing",
	})
	if !thumbnail.IsDiscard(err) {
		t.Fatalf("got %v, want discard", err)
	}
}

func TestThumbnailProcessorDeletesOutputWhenSourceChanges(t *testing.T) {
	store := newImageThumbnailStore(t)
	store.changeSourceOnPut = true
	processor := &ThumbnailProcessor{store: store}
	err := processor.Process(context.Background(), thumbnail.Job{
		Version:     thumbnail.JobVersion,
		FileKey:     "files/alice/photo.png",
		ContentType: "image/png",
		Checksum:    "source-checksum",
	})
	if !thumbnail.IsDiscard(err) {
		t.Fatalf("got %v, want discard", err)
	}
	if _, ok := store.objects["thumbs/alice/photo.png"]; ok {
		t.Fatal("stale thumbnail was not deleted")
	}
}

func TestThumbnailProcessorGeneratesPDFThumbnail(t *testing.T) {
	if _, err := exec.LookPath("pdftoppm"); err != nil {
		t.Skip("pdftoppm not available")
	}

	const checksum = "pdf-checksum"
	store := &memoryThumbnailStore{
		objects: map[string]memoryThumbnailObject{
			"files/alice/doc.pdf": {
				data: minimalPDF(),
				info: minio.ObjectInfo{
					Key:          "files/alice/doc.pdf",
					Size:         int64(len(minimalPDF())),
					ContentType:  "application/pdf",
					UserMetadata: map[string]string{"Checksum": checksum},
				},
			},
		},
	}
	processor := &ThumbnailProcessor{store: store}

	err := processor.Process(context.Background(), thumbnail.Job{
		Version:     thumbnail.JobVersion,
		FileKey:     "files/alice/doc.pdf",
		ContentType: "application/pdf",
		Checksum:    checksum,
	})
	if err != nil {
		t.Fatal(err)
	}

	thumb, ok := store.objects["thumbs/alice/doc.pdf"]
	if !ok {
		t.Fatal("pdf thumbnail was not stored")
	}
	if thumb.info.ContentType != "image/jpeg" {
		t.Fatalf("content type=%q, want image/jpeg", thumb.info.ContentType)
	}
	if len(thumb.data) < 2 || thumb.data[0] != 0xff || thumb.data[1] != 0xd8 {
		t.Fatalf("thumbnail is not a jpeg: first bytes % x", thumb.data[:min(len(thumb.data), 8)])
	}
	if metadataValue(thumb.info.UserMetadata, "Source-Checksum") != checksum {
		t.Fatalf("unexpected metadata: %+v", thumb.info.UserMetadata)
	}
}

func newImageThumbnailStore(t *testing.T) *memoryThumbnailStore {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 16, 16))
	for y := 0; y < 16; y++ {
		for x := 0; x < 16; x++ {
			img.Set(x, y, color.RGBA{R: 200, G: 20, B: 40, A: 255})
		}
	}
	var data bytes.Buffer
	if err := png.Encode(&data, img); err != nil {
		t.Fatal(err)
	}
	return &memoryThumbnailStore{
		objects: map[string]memoryThumbnailObject{
			"files/alice/photo.png": {
				data: data.Bytes(),
				info: minio.ObjectInfo{
					Key:          "files/alice/photo.png",
					Size:         int64(data.Len()),
					ContentType:  "image/png",
					UserMetadata: map[string]string{"Checksum": "source-checksum"},
				},
			},
		},
	}
}

func minimalPDF() []byte {
	return []byte(`%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>
endobj
4 0 obj
<< /Length 44 >>
stream
0.9 0.2 0.1 rg
20 20 160 160 re
f
endstream
endobj
xref
0 5
0000000000 65535 f 
0000000010 00000 n 
0000000061 00000 n 
0000000118 00000 n 
0000000207 00000 n 
trailer
<< /Root 1 0 R /Size 5 >>
startxref
301
%%EOF
`)
}
