package worker

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/png"
	"io"
	"log/slog"
	"os"
	"os/exec"
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

// GenerateThumbnail creates a thumbnail for the given file.
// For images, it resizes directly. For videos, it extracts the first frame
// using ffmpeg. Unsupported types are skipped.
func (w *ThumbnailWorker) GenerateThumbnail(ctx context.Context, fileKey, contentType string) error {
	thumbKey := fileToThumbKey(fileKey)
	if thumbKey == "" {
		return fmt.Errorf("cannot derive thumbnail key from %q", fileKey)
	}

	if strings.HasPrefix(contentType, "image/") {
		return w.generateImageThumbnail(ctx, fileKey, thumbKey)
	}
	if strings.HasPrefix(contentType, "video/") {
		return w.generateVideoThumbnail(ctx, fileKey, thumbKey)
	}

	slog.Info("skipping thumbnail for unsupported type", "key", fileKey, "content_type", contentType)
	return nil
}

func (w *ThumbnailWorker) generateImageThumbnail(ctx context.Context, fileKey, thumbKey string) error {
	obj, err := w.store.GetObject(ctx, fileKey)
	if err != nil {
		return fmt.Errorf("get object %q: %w", fileKey, err)
	}
	defer obj.Close()

	src, _, err := image.Decode(obj)
	if err != nil {
		return fmt.Errorf("decode image %q: %w", fileKey, err)
	}

	return w.resizeAndStore(ctx, thumbKey, src)
}

func (w *ThumbnailWorker) generateVideoThumbnail(ctx context.Context, fileKey, thumbKey string) error {
	// Download video to a temp file for ffmpeg.
	obj, err := w.store.GetObject(ctx, fileKey)
	if err != nil {
		return fmt.Errorf("get object %q: %w", fileKey, err)
	}
	defer obj.Close()

	tmpIn, err := os.CreateTemp("", "reliquary-video-*")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	defer os.Remove(tmpIn.Name())
	defer tmpIn.Close()

	if _, err := io.Copy(tmpIn, obj); err != nil {
		return fmt.Errorf("download video: %w", err)
	}
	tmpIn.Close()

	// Extract first frame with ffmpeg.
	tmpOut, err := os.CreateTemp("", "reliquary-frame-*.jpg")
	if err != nil {
		return fmt.Errorf("create temp output: %w", err)
	}
	defer os.Remove(tmpOut.Name())
	tmpOut.Close()

	cmd := exec.CommandContext(ctx, "ffmpeg",
		"-i", tmpIn.Name(),
		"-vframes", "1",
		"-vf", fmt.Sprintf("scale=%d:-1", thumbWidth),
		"-q:v", "2",
		"-y",
		tmpOut.Name(),
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ffmpeg extract frame: %w\noutput: %s", err, output)
	}

	// Read the frame and upload.
	frameData, err := os.ReadFile(tmpOut.Name())
	if err != nil {
		return fmt.Errorf("read frame: %w", err)
	}

	if err := w.store.PutObject(ctx, thumbKey, bytes.NewReader(frameData), int64(len(frameData)), "image/jpeg", nil); err != nil {
		return fmt.Errorf("put video thumbnail %q: %w", thumbKey, err)
	}

	slog.Info("video thumbnail generated", "key", thumbKey, "size", len(frameData))
	return nil
}

func (w *ThumbnailWorker) resizeAndStore(ctx context.Context, thumbKey string, src image.Image) error {
	bounds := src.Bounds()
	origW := bounds.Dx()
	origH := bounds.Dy()

	var img image.Image
	if origW <= thumbWidth {
		img = src
	} else {
		ratio := float64(thumbWidth) / float64(origW)
		newH := int(float64(origH) * ratio)
		dst := image.NewRGBA(image.Rect(0, 0, thumbWidth, newH))
		draw.CatmullRom.Scale(dst, dst.Bounds(), src, bounds, draw.Over, nil)
		img = dst
	}

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: thumbQuality}); err != nil {
		return fmt.Errorf("encode jpeg: %w", err)
	}

	if err := w.store.PutObject(ctx, thumbKey, &buf, int64(buf.Len()), "image/jpeg", nil); err != nil {
		return fmt.Errorf("put thumbnail %q: %w", thumbKey, err)
	}

	slog.Info("thumbnail generated", "key", thumbKey, "size", buf.Len())
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
