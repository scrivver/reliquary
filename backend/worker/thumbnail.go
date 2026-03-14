package worker

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/png"
	"log/slog"
	"strings"

	"golang.org/x/image/draw"

	"reliquary-be/storage"
)

const (
	thumbWidth   = 300
	thumbQuality = 80
)

type ThumbnailWorker struct {
	store *storage.Client
}

func NewThumbnailWorker(store *storage.Client) *ThumbnailWorker {
	return &ThumbnailWorker{store: store}
}

// GenerateThumbnail reads the original image from MinIO, resizes it, and
// stores the thumbnail. fileKey is e.g. "user/files/2026/03/img.jpg",
// the thumbnail is stored at "user/thumbs/2026/03/img.jpg".
func (w *ThumbnailWorker) GenerateThumbnail(ctx context.Context, fileKey string) error {
	thumbKey := fileToThumbKey(fileKey)
	if thumbKey == "" {
		return fmt.Errorf("cannot derive thumbnail key from %q", fileKey)
	}

	obj, err := w.store.GetObject(ctx, fileKey)
	if err != nil {
		return fmt.Errorf("get object %q: %w", fileKey, err)
	}
	defer obj.Close()

	src, _, err := image.Decode(obj)
	if err != nil {
		return fmt.Errorf("decode image %q: %w", fileKey, err)
	}

	bounds := src.Bounds()
	origW := bounds.Dx()
	origH := bounds.Dy()

	if origW <= thumbWidth {
		// Image is already small enough; store as-is for the thumbnail.
		slog.Info("image already small, copying as thumbnail", "key", fileKey)
		return w.encodeThumbnail(ctx, thumbKey, src)
	}

	ratio := float64(thumbWidth) / float64(origW)
	newH := int(float64(origH) * ratio)

	dst := image.NewRGBA(image.Rect(0, 0, thumbWidth, newH))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, bounds, draw.Over, nil)

	return w.encodeThumbnail(ctx, thumbKey, dst)
}

func (w *ThumbnailWorker) encodeThumbnail(ctx context.Context, key string, img image.Image) error {
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: thumbQuality}); err != nil {
		return fmt.Errorf("encode jpeg: %w", err)
	}

	if err := w.store.PutObject(ctx, key, &buf, int64(buf.Len()), "image/jpeg"); err != nil {
		return fmt.Errorf("put thumbnail %q: %w", key, err)
	}

	slog.Info("thumbnail generated", "key", key, "size", buf.Len())
	return nil
}

// fileToThumbKey converts "user/files/2026/03/img.jpg" to "user/thumbs/2026/03/img.jpg".
func fileToThumbKey(fileKey string) string {
	const filesSegment = "/files/"
	idx := strings.Index(fileKey, filesSegment)
	if idx < 0 {
		return ""
	}
	return fileKey[:idx] + "/thumbs/" + fileKey[idx+len(filesSegment):]
}
