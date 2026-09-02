package storage

import (
	"context"
	"errors"
	"os"
	"testing"

	"reliquary-be/config"
)

// integrationClient builds a Client against a live MinIO. The fake in
// backend/auth proves the retry logic; only a real server proves the 412
// mapping, which is the part that silently breaks on a backend swap.
func integrationClient(t *testing.T) *Client {
	t.Helper()

	endpoint := os.Getenv("MINIO_INTEGRATION_ENDPOINT")
	if endpoint == "" {
		t.Skip("MINIO_INTEGRATION_ENDPOINT is not set")
	}

	cfg := &config.Config{
		MinIOEndpoint:  endpoint,
		MinIOAccessKey: envOrDefault("MINIO_INTEGRATION_ACCESS_KEY", "minioadmin"),
		MinIOSecretKey: envOrDefault("MINIO_INTEGRATION_SECRET_KEY", "minioadmin"),
		MinIOBucket:    envOrDefault("MINIO_INTEGRATION_BUCKET", "reliquary"),
	}
	client, err := New(cfg)
	if err != nil {
		t.Fatalf("connect to MinIO at %s: %v", endpoint, err)
	}
	return client
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func scratchKey(t *testing.T, c *Client) string {
	t.Helper()
	key := "admin/.test-" + t.Name()
	t.Cleanup(func() {
		if err := c.DeleteObject(context.Background(), key); err != nil && !IsObjectNotFound(err) {
			t.Logf("cleanup %s: %v", key, err)
		}
	})
	return key
}

func TestIntegrationGetObjectWithETag_Missing(t *testing.T) {
	c := integrationClient(t)
	ctx := context.Background()

	_, _, ok, err := c.GetObjectWithETag(ctx, "admin/.definitely-does-not-exist")
	if err != nil {
		t.Fatalf("a missing object is a normal state, not an error: %v", err)
	}
	if ok {
		t.Fatal("ok should be false for a missing object")
	}
}

func TestIntegrationConditionalWriteRoundTrip(t *testing.T) {
	c := integrationClient(t)
	ctx := context.Background()
	key := scratchKey(t, c)

	// Create-only on a fresh key succeeds.
	first, err := c.PutObjectIfUnchanged(ctx, key, []byte(`{"v":1}`), "application/json", "")
	if err != nil {
		t.Fatalf("create-only write on fresh key: %v", err)
	}

	// Read back the bytes and the ETag we just wrote.
	data, etag, ok, err := c.GetObjectWithETag(ctx, key)
	if err != nil || !ok {
		t.Fatalf("read back: err=%v ok=%v", err, ok)
	}
	if string(data) != `{"v":1}` {
		t.Fatalf("data = %q, want %q", data, `{"v":1}`)
	}
	if etag != first {
		t.Fatalf("ETag from read (%q) disagrees with ETag from write (%q); "+
			"quoting or normalisation is wrong and CAS would never converge", etag, first)
	}

	// Create-only against an existing key is refused.
	if _, err := c.PutObjectIfUnchanged(ctx, key, []byte(`{"v":2}`), "application/json", ""); !errors.Is(err, ErrPreconditionFailed) {
		t.Fatalf("create-only on existing key: got %v, want ErrPreconditionFailed", err)
	}

	// A write carrying the current ETag succeeds and advances it.
	second, err := c.PutObjectIfUnchanged(ctx, key, []byte(`{"v":3}`), "application/json", first)
	if err != nil {
		t.Fatalf("write with current ETag: %v", err)
	}
	if second == first {
		t.Fatal("ETag did not change after a write; it cannot identify a version")
	}

	// A write carrying the superseded ETag is refused. This is the property the
	// whole fix rests on.
	if _, err := c.PutObjectIfUnchanged(ctx, key, []byte(`{"v":4}`), "application/json", first); !errors.Is(err, ErrPreconditionFailed) {
		t.Fatalf("write with superseded ETag: got %v, want ErrPreconditionFailed", err)
	}

	// The refused writes left the object on the last accepted version.
	data, _, _, err = c.GetObjectWithETag(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"v":3}` {
		t.Fatalf("data = %q, want %q: a refused write modified the object", data, `{"v":3}`)
	}
}

// TestIntegrationQuotedETagAccepted guards the normalisation seam: a caller
// handing back a quoted ETag (as some backends return) must still match.
func TestIntegrationQuotedETagAccepted(t *testing.T) {
	c := integrationClient(t)
	ctx := context.Background()
	key := scratchKey(t, c)

	etag, err := c.PutObjectIfUnchanged(ctx, key, []byte(`{"v":1}`), "application/json", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.PutObjectIfUnchanged(ctx, key, []byte(`{"v":2}`), "application/json", `"`+etag+`"`); err != nil {
		t.Fatalf("quoted ETag should be accepted: %v", err)
	}
}

func TestIntegrationVerifyConditionalWrites(t *testing.T) {
	c := integrationClient(t)
	if err := c.VerifyConditionalWrites(context.Background()); err != nil {
		t.Fatalf("preflight failed against live backend: %v", err)
	}
}

// TestIntegrationPreflightLeavesNoObject checks the scratch key is cleaned up,
// so a preflight on every process start does not accumulate objects.
func TestIntegrationPreflightLeavesNoObject(t *testing.T) {
	c := integrationClient(t)
	ctx := context.Background()

	before, err := c.ListObjects(ctx, "admin/.cas-preflight-")
	if err != nil {
		t.Fatal(err)
	}
	if err := c.VerifyConditionalWrites(ctx); err != nil {
		t.Fatal(err)
	}
	after, err := c.ListObjects(ctx, "admin/.cas-preflight-")
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != len(before) {
		t.Fatalf("preflight leaked objects: %d before, %d after", len(before), len(after))
	}
}

// TestIntegrationConcurrentPreflights covers replicas starting together: each
// uses its own scratch key, so they must not interfere.
func TestIntegrationConcurrentPreflights(t *testing.T) {
	c := integrationClient(t)
	ctx := context.Background()

	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		go func() { errs <- c.VerifyConditionalWrites(ctx) }()
	}
	for i := 0; i < 4; i++ {
		if err := <-errs; err != nil {
			t.Fatalf("concurrent preflight failed: %v", err)
		}
	}
}
