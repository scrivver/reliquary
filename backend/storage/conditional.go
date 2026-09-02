package storage

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/minio/minio-go/v7"
)

// ErrPreconditionFailed reports that a conditional write lost the race: the
// stored object changed after the caller read it, so the write was refused.
// Callers re-read and re-apply rather than retrying the same bytes.
var ErrPreconditionFailed = errors.New("storage: precondition failed")

// normalizeETag strips the quotes S3 wraps around entity tags. They are present
// on some responses and absent on others; comparing a quoted tag against an
// unquoted one looks like a permanent conflict, which would retry forever.
func normalizeETag(etag string) string {
	return strings.Trim(etag, `"`)
}

// isPreconditionFailed reports whether err is a 412 from a conditional write.
// The code string is checked first because it is what MinIO returns, and the
// status second so a backend using a different code still maps correctly.
func isPreconditionFailed(err error) bool {
	if err == nil {
		return false
	}
	resp := minio.ToErrorResponse(err)
	return resp.Code == "PreconditionFailed" || resp.StatusCode == http.StatusPreconditionFailed
}

// GetObjectWithETag reads an object together with the ETag identifying the
// version read. ok is false when the object does not exist, which is a normal
// state for a store that has not been written yet, not an error.
func (c *Client) GetObjectWithETag(ctx context.Context, key string) (data []byte, etag string, ok bool, err error) {
	obj, err := c.mc.GetObject(ctx, c.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		if IsObjectNotFound(err) {
			return nil, "", false, nil
		}
		return nil, "", false, err
	}
	defer obj.Close()

	// GetObject is lazy: a missing key only surfaces on Stat or the first read.
	info, err := obj.Stat()
	if err != nil {
		if IsObjectNotFound(err) {
			return nil, "", false, nil
		}
		return nil, "", false, err
	}

	data, err = io.ReadAll(obj)
	if err != nil {
		return nil, "", false, err
	}
	return data, normalizeETag(info.ETag), true, nil
}

// PutObjectIfUnchanged writes data only if the stored object's ETag still
// equals expectedETag, returning the ETag of the version just written. An empty
// expectedETag means "only if the object does not exist", so a caller that read
// nothing cannot clobber an object created since.
//
// Returns ErrPreconditionFailed when the condition does not hold.
func (c *Client) PutObjectIfUnchanged(
	ctx context.Context,
	key string,
	data []byte,
	contentType string,
	expectedETag string,
) (string, error) {
	opts := minio.PutObjectOptions{ContentType: contentType}
	if expectedETag == "" {
		opts.SetMatchETagExcept("*")
	} else {
		opts.SetMatchETag(normalizeETag(expectedETag))
	}

	info, err := c.mc.PutObject(ctx, c.bucket, key, bytes.NewReader(data), int64(len(data)), opts)
	if err != nil {
		if isPreconditionFailed(err) {
			return "", fmt.Errorf("%w: %q changed since it was read", ErrPreconditionFailed, key)
		}
		return "", err
	}
	return normalizeETag(info.ETag), nil
}

// VerifyConditionalWrites checks that the backend actually enforces If-Match.
//
// A backend that accepts the header and ignores it is the dangerous case: every
// write succeeds, no error is ever raised, and the lost updates this mechanism
// exists to prevent come back silently. Tests against MinIO would still pass.
// So this is checked against the live backend at startup rather than assumed.
//
// The scratch key carries a random suffix: two replicas starting together must
// not run this against the same key, or one can observe the other's write and
// wrongly conclude the backend is broken.
func (c *Client) VerifyConditionalWrites(ctx context.Context) error {
	suffix := make([]byte, 8)
	if _, err := rand.Read(suffix); err != nil {
		return fmt.Errorf("generate preflight key: %w", err)
	}
	key := "admin/.cas-preflight-" + hex.EncodeToString(suffix)
	defer func() {
		if err := c.DeleteObject(context.WithoutCancel(ctx), key); err != nil {
			slog.Warn("failed to clean up conditional write preflight object", "key", key, "error", err)
		}
	}()

	// A first write must be create-only, and must succeed on a fresh key.
	first, err := c.PutObjectIfUnchanged(ctx, key, []byte(`{"preflight":1}`), "application/json", "")
	if err != nil {
		return fmt.Errorf("conditional write preflight: create-only write failed: %w", err)
	}

	// The same create-only write must now be refused.
	if _, err := c.PutObjectIfUnchanged(ctx, key, []byte(`{"preflight":2}`), "application/json", ""); !errors.Is(err, ErrPreconditionFailed) {
		return fmt.Errorf(
			"conditional write preflight: backend does not enforce If-None-Match; "+
				"a create-only write to an existing key was not refused (err=%v)", err,
		)
	}

	// A write carrying the current ETag must succeed, and must advance it.
	second, err := c.PutObjectIfUnchanged(ctx, key, []byte(`{"preflight":3}`), "application/json", first)
	if err != nil {
		return fmt.Errorf("conditional write preflight: write with current ETag failed: %w", err)
	}
	if second == first {
		return fmt.Errorf("conditional write preflight: ETag did not change after a write; it cannot identify a version")
	}

	// A write carrying the superseded ETag must be refused. This is the check
	// that matters: without it, stale writers silently win.
	if _, err := c.PutObjectIfUnchanged(ctx, key, []byte(`{"preflight":4}`), "application/json", first); !errors.Is(err, ErrPreconditionFailed) {
		return fmt.Errorf(
			"conditional write preflight: backend does not enforce If-Match; "+
				"a write with a superseded ETag was accepted (err=%v)", err,
		)
	}

	return nil
}

// EnsureConditionalWrites runs the preflight and fails startup if the backend
// does not enforce conditional writes, unless the operator has explicitly
// opted out.
//
// Failing closed is deliberate. The alternative — a warning — leaves a
// deployment running on a backend where concurrent writers silently revert each
// other, which is precisely the defect conditional writes were adopted to fix,
// and which produces no error at the time it happens.
func EnsureConditionalWrites(ctx context.Context, c *Client, skip bool) error {
	if skip {
		slog.Warn(
			"skipping conditional write preflight; concurrent writers may silently " +
				"revert each other's changes to the user store",
		)
		return nil
	}

	if err := c.VerifyConditionalWrites(ctx); err != nil {
		return fmt.Errorf(
			"%w\nThe object storage backend must support conditional writes (If-Match / "+
				"If-None-Match) for safe concurrent access to the user store. Set "+
				"STORAGE_INSECURE_SKIP_CAS_PREFLIGHT=true to start anyway, accepting "+
				"that concurrent writers can silently revert each other",
			err,
		)
	}
	slog.Info("conditional writes verified; user store mutations are compare-and-swap")
	return nil
}
