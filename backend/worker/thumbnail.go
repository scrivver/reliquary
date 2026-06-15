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

	"github.com/minio/minio-go/v7"
	"golang.org/x/image/draw"

	"reliquary-be/storage"
	"reliquary-be/thumbnail"
)

const (
	thumbWidth   = 300
	thumbQuality = 80
)

type thumbnailStore interface {
	GetObject(ctx context.Context, key string) (io.ReadCloser, error)
	PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string, userMeta map[string]string) error
	DeleteObject(ctx context.Context, key string) error
	StatObject(ctx context.Context, key string) (minio.ObjectInfo, error)
}

// ThumbnailProcessor synchronously renders one durable thumbnail job.
type ThumbnailProcessor struct {
	store thumbnailStore
}

func NewThumbnailProcessor(store *storage.Client) *ThumbnailProcessor {
	return &ThumbnailProcessor{store: store}
}

func (p *ThumbnailProcessor) Process(ctx context.Context, job thumbnail.Job) error {
	if err := job.Validate(); err != nil {
		return thumbnail.Discard(err)
	}
	if !thumbnail.SupportedContentType(job.ContentType) {
		return thumbnail.Discard(fmt.Errorf("unsupported content type %q", job.ContentType))
	}

	thumbKey := fileToThumbKey(job.FileKey)
	if thumbKey == "" {
		return thumbnail.Discard(fmt.Errorf("cannot derive thumbnail key from %q", job.FileKey))
	}

	matches, err := p.sourceMatches(ctx, job)
	if err != nil {
		return err
	}
	if !matches {
		return thumbnail.Discard(fmt.Errorf("source is missing or checksum changed"))
	}

	if stat, err := p.store.StatObject(ctx, thumbKey); err == nil {
		if metadataValue(stat.UserMetadata, "Source-Checksum") == job.Checksum {
			slog.Debug("thumbnail already current", "key", thumbKey)
			return nil
		}
	} else if !storage.IsObjectNotFound(err) {
		return fmt.Errorf("stat thumbnail %q: %w", thumbKey, err)
	}

	data, err := p.generate(ctx, job.FileKey, job.ContentType)
	if err != nil {
		return err
	}
	meta := map[string]string{"Source-Checksum": job.Checksum}
	if err := p.store.PutObject(
		ctx,
		thumbKey,
		bytes.NewReader(data),
		int64(len(data)),
		"image/jpeg",
		meta,
	); err != nil {
		return fmt.Errorf("put thumbnail %q: %w", thumbKey, err)
	}

	matches, err = p.sourceMatches(ctx, job)
	if err != nil {
		p.store.DeleteObject(ctx, thumbKey)
		return err
	}
	if !matches {
		if err := p.store.DeleteObject(ctx, thumbKey); err != nil {
			return fmt.Errorf("delete stale thumbnail %q: %w", thumbKey, err)
		}
		return thumbnail.Discard(fmt.Errorf("source changed during generation"))
	}

	slog.Info("thumbnail generated", "key", thumbKey, "size", len(data))
	return nil
}

func (p *ThumbnailProcessor) sourceMatches(
	ctx context.Context,
	job thumbnail.Job,
) (bool, error) {
	stat, err := p.store.StatObject(ctx, job.FileKey)
	if err != nil {
		if storage.IsObjectNotFound(err) {
			return false, nil
		}
		return false, fmt.Errorf("stat source %q: %w", job.FileKey, err)
	}
	return metadataValue(stat.UserMetadata, "Checksum") == job.Checksum, nil
}

func (p *ThumbnailProcessor) generate(
	ctx context.Context,
	fileKey string,
	contentType string,
) ([]byte, error) {
	switch {
	case strings.HasPrefix(contentType, "image/"):
		return p.generateImageThumbnail(ctx, fileKey)
	case strings.HasPrefix(contentType, "video/"):
		return p.generateVideoThumbnail(ctx, fileKey)
	case contentType == "application/pdf":
		return p.generatePDFThumbnail(ctx, fileKey)
	default:
		return nil, thumbnail.Discard(fmt.Errorf("unsupported content type %q", contentType))
	}
}

func (p *ThumbnailProcessor) generateImageThumbnail(
	ctx context.Context,
	fileKey string,
) ([]byte, error) {
	obj, err := p.store.GetObject(ctx, fileKey)
	if err != nil {
		return nil, fmt.Errorf("get object %q: %w", fileKey, err)
	}
	defer obj.Close()

	src, _, err := image.Decode(obj)
	if err != nil {
		return nil, fmt.Errorf("decode image %q: %w", fileKey, err)
	}

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
		return nil, fmt.Errorf("encode jpeg: %w", err)
	}
	return buf.Bytes(), nil
}

func (p *ThumbnailProcessor) generateVideoThumbnail(
	ctx context.Context,
	fileKey string,
) ([]byte, error) {
	obj, err := p.store.GetObject(ctx, fileKey)
	if err != nil {
		return nil, fmt.Errorf("get object %q: %w", fileKey, err)
	}
	defer obj.Close()

	tmpIn, err := os.CreateTemp("", "reliquary-video-*")
	if err != nil {
		return nil, fmt.Errorf("create temp file: %w", err)
	}
	defer os.Remove(tmpIn.Name())
	defer tmpIn.Close()

	if _, err := io.Copy(tmpIn, obj); err != nil {
		return nil, fmt.Errorf("download video: %w", err)
	}
	tmpIn.Close()

	tmpOut, err := os.CreateTemp("", "reliquary-frame-*.jpg")
	if err != nil {
		return nil, fmt.Errorf("create temp output: %w", err)
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
		return nil, fmt.Errorf("ffmpeg extract frame: %w\noutput: %s", err, output)
	}

	frameData, err := os.ReadFile(tmpOut.Name())
	if err != nil {
		return nil, fmt.Errorf("read frame: %w", err)
	}
	return frameData, nil
}

func (p *ThumbnailProcessor) generatePDFThumbnail(
	ctx context.Context,
	fileKey string,
) ([]byte, error) {
	obj, err := p.store.GetObject(ctx, fileKey)
	if err != nil {
		return nil, fmt.Errorf("get object %q: %w", fileKey, err)
	}
	defer obj.Close()

	tmpIn, err := os.CreateTemp("", "reliquary-pdf-*.pdf")
	if err != nil {
		return nil, fmt.Errorf("create temp file: %w", err)
	}
	defer os.Remove(tmpIn.Name())
	defer tmpIn.Close()

	if _, err := io.Copy(tmpIn, obj); err != nil {
		return nil, fmt.Errorf("download pdf: %w", err)
	}
	tmpIn.Close()

	tmpOutPrefix, err := os.CreateTemp("", "reliquary-pdfthumb-")
	if err != nil {
		return nil, fmt.Errorf("create temp output: %w", err)
	}
	tmpOutBase := tmpOutPrefix.Name()
	tmpOutPrefix.Close()
	os.Remove(tmpOutBase)

	cmd := exec.CommandContext(ctx, "pdftoppm",
		"-jpeg",
		"-f", "1",
		"-l", "1",
		"-scale-to", fmt.Sprintf("%d", thumbWidth),
		tmpIn.Name(),
		tmpOutBase,
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("pdftoppm render: %w\noutput: %s", err, output)
	}

	outFile := tmpOutBase + "-1.jpg"
	defer os.Remove(outFile)

	pageData, err := os.ReadFile(outFile)
	if err != nil {
		return nil, fmt.Errorf("read pdf page: %w", err)
	}
	return pageData, nil
}

func metadataValue(metadata map[string]string, key string) string {
	for metadataKey, value := range metadata {
		if strings.EqualFold(metadataKey, key) {
			return value
		}
	}
	return ""
}

// fileToThumbKey converts "files/<user>/2026/03/img.jpg" to
// "thumbs/<user>/2026/03/img.jpg".
func fileToThumbKey(fileKey string) string {
	const filesSegment = "files/"
	if !strings.HasPrefix(fileKey, filesSegment) {
		return ""
	}
	return "thumbs/" + strings.TrimPrefix(fileKey, filesSegment)
}
