package storage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
)

var ErrFileIndexNotFound = errors.New("file index not found")

type FileIndexItem struct {
	Key          string    `json:"key"`
	Size         int64     `json:"size"`
	ContentType  string    `json:"content_type"`
	LastModified time.Time `json:"last_modified"`
	Checksum     string    `json:"checksum,omitempty"`
	UploadDate   string    `json:"upload_date,omitempty"`
	OriginalName string    `json:"original_name,omitempty"`
}

type FileManifest struct {
	Version   int             `json:"version"`
	UpdatedAt time.Time       `json:"updated_at"`
	Files     []FileIndexItem `json:"files"`
}

type fileIndexObjectStore interface {
	GetObject(ctx context.Context, key string) (io.ReadCloser, error)
	PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string, userMeta map[string]string) error
	DeleteObject(ctx context.Context, key string) error
	ListObjects(ctx context.Context, prefix string) ([]minio.ObjectInfo, error)
	StatObject(ctx context.Context, key string) (minio.ObjectInfo, error)
}

type FileIndex struct {
	store fileIndexObjectStore
}

func NewFileIndex(store *Client) *FileIndex {
	return &FileIndex{store: store}
}

func FileIndexKey(username string) string {
	return "indexes/" + username + "/files.json"
}

func (idx *FileIndex) Ensure(ctx context.Context, username string) error {
	_, err := idx.Load(ctx, username)
	if err == nil {
		return nil
	}
	if !errors.Is(err, ErrFileIndexNotFound) {
		return err
	}
	return idx.save(ctx, username, FileManifest{Version: 1})
}

func (idx *FileIndex) Load(ctx context.Context, username string) (FileManifest, error) {
	obj, err := idx.store.GetObject(ctx, FileIndexKey(username))
	if err != nil {
		if IsObjectNotFound(err) {
			return FileManifest{}, ErrFileIndexNotFound
		}
		return FileManifest{}, err
	}
	defer obj.Close()

	data, err := io.ReadAll(obj)
	if err != nil {
		if IsObjectNotFound(err) {
			return FileManifest{}, ErrFileIndexNotFound
		}
		return FileManifest{}, err
	}
	if len(data) == 0 {
		return FileManifest{}, ErrFileIndexNotFound
	}

	var manifest FileManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return FileManifest{}, fmt.Errorf("parse file index: %w", err)
	}
	if manifest.Version == 0 {
		manifest.Version = 1
	}
	sortFileIndexItems(manifest.Files)
	return manifest, nil
}

func (idx *FileIndex) Upsert(ctx context.Context, username string, item FileIndexItem) error {
	manifest, err := idx.Load(ctx, username)
	if err != nil {
		if !errors.Is(err, ErrFileIndexNotFound) {
			return err
		}
		manifest = FileManifest{Version: 1}
	}

	replaced := false
	for i, existing := range manifest.Files {
		if existing.Key == item.Key {
			manifest.Files[i] = item
			replaced = true
			break
		}
	}
	if !replaced {
		manifest.Files = append(manifest.Files, item)
	}
	return idx.save(ctx, username, manifest)
}

func (idx *FileIndex) Remove(ctx context.Context, username, key string) error {
	manifest, err := idx.Load(ctx, username)
	if err != nil {
		if errors.Is(err, ErrFileIndexNotFound) {
			return nil
		}
		return err
	}

	files := manifest.Files[:0]
	for _, item := range manifest.Files {
		if item.Key != key {
			files = append(files, item)
		}
	}
	manifest.Files = files
	return idx.save(ctx, username, manifest)
}

func (idx *FileIndex) DeleteUser(ctx context.Context, username string) error {
	if err := idx.store.DeleteObject(ctx, FileIndexKey(username)); err != nil && !IsObjectNotFound(err) {
		return err
	}
	return nil
}

func (idx *FileIndex) Rebuild(ctx context.Context, username string) (FileManifest, error) {
	prefix := fmt.Sprintf("files/%s/", username)
	objects, err := idx.store.ListObjects(ctx, prefix)
	if err != nil {
		return FileManifest{}, err
	}

	files := make([]FileIndexItem, 0, len(objects))
	for _, obj := range objects {
		item := FileIndexItem{
			Key:          obj.Key,
			Size:         obj.Size,
			ContentType:  contentTypeForObject(obj),
			LastModified: obj.LastModified,
		}
		if stat, err := idx.store.StatObject(ctx, obj.Key); err == nil {
			if stat.Size != 0 {
				item.Size = stat.Size
			}
			if stat.LastModified.IsZero() {
				item.LastModified = obj.LastModified
			} else {
				item.LastModified = stat.LastModified
			}
			if stat.ContentType != "" {
				item.ContentType = stat.ContentType
			}
			item.Checksum = stat.UserMetadata["Checksum"]
			item.UploadDate = stat.UserMetadata["Upload-Date"]
			item.OriginalName = stat.UserMetadata["Original-Name"]
		}
		files = append(files, item)
	}

	manifest := FileManifest{
		Version: 1,
		Files:   files,
	}
	if err := idx.save(ctx, username, manifest); err != nil {
		return FileManifest{}, err
	}
	return manifest, nil
}

func (idx *FileIndex) save(ctx context.Context, username string, manifest FileManifest) error {
	manifest.Version = 1
	manifest.UpdatedAt = time.Now().UTC()
	sortFileIndexItems(manifest.Files)

	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	return idx.store.PutObject(
		ctx,
		FileIndexKey(username),
		bytes.NewReader(data),
		int64(len(data)),
		"application/json",
		nil,
	)
}

func ComputeStatsFromManifest(manifest FileManifest) UserStats {
	stats := UserStats{
		ByType:  make(map[string]int),
		ByMonth: make(map[string]int),
	}
	for _, item := range manifest.Files {
		stats.FileCount++
		stats.TotalSize += item.Size

		ct := item.ContentType
		if ct == "" {
			ct = contentTypeFromKey(item.Key)
		}
		major := strings.SplitN(ct, "/", 2)[0]
		stats.ByType[major]++

		if month := extractMonth(item.Key, ownerFilesPrefix(item.Key)); month != "" {
			stats.ByMonth[month]++
		}
	}
	return stats
}

func FileIndexItemFromObject(obj minio.ObjectInfo, checksum, uploadDate, originalName string) FileIndexItem {
	return FileIndexItem{
		Key:          obj.Key,
		Size:         obj.Size,
		ContentType:  contentTypeForObject(obj),
		LastModified: obj.LastModified,
		Checksum:     checksum,
		UploadDate:   uploadDate,
		OriginalName: originalName,
	}
}

func contentTypeForObject(obj minio.ObjectInfo) string {
	if obj.ContentType != "" {
		return obj.ContentType
	}
	return contentTypeFromKey(obj.Key)
}

func contentTypeFromKey(key string) string {
	ct := mime.TypeByExtension(path.Ext(key))
	if ct == "" {
		return "application/octet-stream"
	}
	return ct
}

func sortFileIndexItems(files []FileIndexItem) {
	sort.SliceStable(files, func(i, j int) bool {
		return files[i].Key < files[j].Key
	})
}

func ownerFilesPrefix(key string) string {
	parts := strings.SplitN(key, "/", 3)
	if len(parts) < 2 || parts[0] != "files" {
		return ""
	}
	return "files/" + parts[1] + "/"
}
