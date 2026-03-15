package storage

import (
	"context"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"

	"reliquary-be/config"
)

type Client struct {
	mc     *minio.Client
	bucket string
}

func New(cfg *config.Config) (*Client, error) {
	mc, err := minio.New(cfg.MinIOEndpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(cfg.MinIOAccessKey, cfg.MinIOSecretKey, ""),
		Secure: cfg.MinIOUseSSL,
	})
	if err != nil {
		return nil, fmt.Errorf("minio client: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	exists, err := mc.BucketExists(ctx, cfg.MinIOBucket)
	if err != nil {
		return nil, fmt.Errorf("check bucket: %w", err)
	}
	if !exists {
		return nil, fmt.Errorf("bucket %q does not exist; is infra running?", cfg.MinIOBucket)
	}

	return &Client{mc: mc, bucket: cfg.MinIOBucket}, nil
}

func (c *Client) PresignPut(ctx context.Context, key, contentType string) (*url.URL, error) {
	return c.mc.PresignedPutObject(ctx, c.bucket, key, 15*time.Minute)
}

func (c *Client) PresignGet(ctx context.Context, key string, forceDownload bool) (*url.URL, error) {
	params := make(url.Values)
	if forceDownload {
		// Extract filename from key for the download name.
		parts := strings.Split(key, "/")
		filename := parts[len(parts)-1]
		params.Set("response-content-disposition", "attachment; filename=\""+filename+"\"")
	}
	return c.mc.PresignedGetObject(ctx, c.bucket, key, 15*time.Minute, params)
}

func (c *Client) ListObjects(ctx context.Context, prefix string) ([]minio.ObjectInfo, error) {
	var objects []minio.ObjectInfo
	for obj := range c.mc.ListObjects(ctx, c.bucket, minio.ListObjectsOptions{
		Prefix:    prefix,
		Recursive: true,
	}) {
		if obj.Err != nil {
			return nil, obj.Err
		}
		objects = append(objects, obj)
	}
	return objects, nil
}

func (c *Client) GetObject(ctx context.Context, key string) (io.ReadCloser, error) {
	obj, err := c.mc.GetObject(ctx, c.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil, err
	}
	return obj, nil
}

func (c *Client) PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string, userMeta map[string]string) error {
	_, err := c.mc.PutObject(ctx, c.bucket, key, reader, size, minio.PutObjectOptions{
		ContentType:  contentType,
		UserMetadata: userMeta,
	})
	return err
}

func (c *Client) DeleteObject(ctx context.Context, key string) error {
	return c.mc.RemoveObject(ctx, c.bucket, key, minio.RemoveObjectOptions{})
}

func (c *Client) StatObject(ctx context.Context, key string) (minio.ObjectInfo, error) {
	return c.mc.StatObject(ctx, c.bucket, key, minio.StatObjectOptions{})
}

// CopyObject copies an object to a new key within the same bucket (server-side).
func (c *Client) CopyObject(ctx context.Context, srcKey, dstKey string) error {
	src := minio.CopySrcOptions{Bucket: c.bucket, Object: srcKey}
	dst := minio.CopyDestOptions{Bucket: c.bucket, Object: dstKey}
	_, err := c.mc.CopyObject(ctx, dst, src)
	return err
}

// MoveObject copies an object to a new key and deletes the original.
func (c *Client) MoveObject(ctx context.Context, srcKey, dstKey string) error {
	if err := c.CopyObject(ctx, srcKey, dstKey); err != nil {
		return fmt.Errorf("copy %q -> %q: %w", srcKey, dstKey, err)
	}
	return c.DeleteObject(ctx, srcKey)
}
