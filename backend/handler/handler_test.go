package handler

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/minio/minio-go/v7"

	"reliquary-be/auth"
	"reliquary-be/event"
	"reliquary-be/storage"
	"reliquary-be/thumbnail"
)

type fakeFileStore struct {
	stat minio.ObjectInfo
}

func (s *fakeFileStore) StatObject(context.Context, string) (minio.ObjectInfo, error) {
	return s.stat, nil
}
func (*fakeFileStore) PutObject(context.Context, string, io.Reader, int64, string, map[string]string) error {
	return nil
}
func (*fakeFileStore) PresignGet(context.Context, string, bool) (*url.URL, error) {
	return nil, nil
}
func (*fakeFileStore) GetObject(context.Context, string) (io.ReadCloser, error) {
	return nil, nil
}
func (*fakeFileStore) DeleteObject(context.Context, string) error {
	return nil
}

type fakeEmitter struct {
	events []event.FileEvent
	err    error
	order  *[]string
}

func (e *fakeEmitter) Emit(_ context.Context, evt event.FileEvent) error {
	if e.order != nil {
		*e.order = append(*e.order, "emit:"+evt.Event)
	}
	e.events = append(e.events, evt)
	return e.err
}
func (*fakeEmitter) Close() error { return nil }

type fakeThumbnailPublisher struct {
	jobs  []thumbnail.Job
	err   error
	order *[]string
}

func (p *fakeThumbnailPublisher) Publish(_ context.Context, job thumbnail.Job) error {
	if p.order != nil {
		*p.order = append(*p.order, "thumbnail:publish")
	}
	p.jobs = append(p.jobs, job)
	return p.err
}
func (*fakeThumbnailPublisher) Close() error { return nil }

type fakeChecksumIndex struct {
	existing map[string]string
	order    *[]string
}

func (*fakeChecksumIndex) LoadUser(context.Context, string) error { return nil }
func (i *fakeChecksumIndex) Lookup(_ string, checksum string) string {
	return i.existing[checksum]
}
func (i *fakeChecksumIndex) Add(context.Context, string, string, string) error {
	if i.order != nil {
		*i.order = append(*i.order, "checksum:add")
	}
	return nil
}
func (i *fakeChecksumIndex) RemoveByKey(context.Context, string, string) error {
	if i.order != nil {
		*i.order = append(*i.order, "checksum:remove")
	}
	return nil
}

type fakeFileIndex struct {
	manifest storage.FileManifest
	err      error
	rebuilds int
	order    *[]string
}

func (i *fakeFileIndex) Ensure(context.Context, string) error {
	return i.err
}
func (i *fakeFileIndex) Load(context.Context, string) (storage.FileManifest, error) {
	if i.err != nil {
		return storage.FileManifest{}, i.err
	}
	return i.manifest, nil
}
func (i *fakeFileIndex) Upsert(_ context.Context, _ string, item storage.FileIndexItem) error {
	if i.order != nil {
		*i.order = append(*i.order, "file-index:upsert")
	}
	i.manifest.Files = append(i.manifest.Files, item)
	return i.err
}
func (i *fakeFileIndex) Remove(context.Context, string, string) error {
	if i.order != nil {
		*i.order = append(*i.order, "file-index:remove")
	}
	return i.err
}
func (i *fakeFileIndex) DeleteUser(context.Context, string) error {
	return i.err
}
func (i *fakeFileIndex) Rebuild(context.Context, string) (storage.FileManifest, error) {
	i.rebuilds++
	if i.err != nil && !errors.Is(i.err, storage.ErrFileIndexNotFound) {
		return storage.FileManifest{}, i.err
	}
	return i.manifest, nil
}

type recordingFileStore struct {
	objects map[string]minio.ObjectInfo
	order   *[]string
}

func (s *recordingFileStore) StatObject(_ context.Context, key string) (minio.ObjectInfo, error) {
	if obj, ok := s.objects[key]; ok {
		return obj, nil
	}
	return minio.ObjectInfo{}, minio.ErrorResponse{Code: "NoSuchKey"}
}
func (s *recordingFileStore) PutObject(_ context.Context, key string, _ io.Reader, size int64, _ string, _ map[string]string) error {
	if s.order != nil {
		*s.order = append(*s.order, "storage:put")
	}
	s.objects[key] = minio.ObjectInfo{
		Key:          key,
		Size:         size,
		LastModified: time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC),
	}
	return nil
}
func (*recordingFileStore) PresignGet(context.Context, string, bool) (*url.URL, error) {
	return nil, nil
}
func (*recordingFileStore) GetObject(context.Context, string) (io.ReadCloser, error) {
	return nil, nil
}
func (s *recordingFileStore) DeleteObject(_ context.Context, key string) error {
	if s.order != nil {
		*s.order = append(*s.order, "storage:delete")
	}
	delete(s.objects, key)
	return nil
}
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

func TestUserOwnsKeyOnlyAllowsActiveNamespaces(t *testing.T) {
	tests := []struct {
		key  string
		want bool
	}{
		{"files/alice/2026/06/report.pdf", true},
		{"thumbs/alice/2026/06/report.pdf", true},
		{"archive/alice/2026/06/report.pdf", false},
		{"archive-thumbs/alice/2026/06/report.pdf", false},
		{"files/bob/2026/06/report.pdf", false},
	}

	for _, tt := range tests {
		if got := UserOwnsKey("alice", tt.key); got != tt.want {
			t.Errorf("UserOwnsKey(%q) = %v, want %v", tt.key, got, tt.want)
		}
	}
}

func TestObjectKeyFromStorageURI(t *testing.T) {
	tests := []struct {
		rawURI  string
		bucket  string
		want    string
		wantErr bool
	}{
		{"/storage/reliquary/files/alice/2026/06/a.jpg?X-Amz-Signature=abc", "reliquary", "files/alice/2026/06/a.jpg", false},
		{"/storage/reliquary/thumbs/alice/2026/06/a.jpg", "reliquary", "thumbs/alice/2026/06/a.jpg", false},
		{"/storage/my%20bucket/files/alice/a%20b.txt", "my bucket", "files/alice/a b.txt", false},
		{"/storage/files/alice/a.jpg", "", "files/alice/a.jpg", false},
		{"/api/auth/check", "reliquary", "api/auth/check", false},
		{"", "reliquary", "", true},
	}
	for _, tt := range tests {
		got, err := objectKeyFromStorageURI(tt.rawURI, tt.bucket)
		if tt.wantErr {
			if err == nil {
				t.Errorf("objectKeyFromStorageURI(%q) = %q, want error", tt.rawURI, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("objectKeyFromStorageURI(%q) unexpected error: %v", tt.rawURI, err)
			continue
		}
		if got != tt.want {
			t.Errorf("objectKeyFromStorageURI(%q) = %q, want %q", tt.rawURI, got, tt.want)
		}
	}
}

func TestAuthCheckAuthorizesOwnedKeys(t *testing.T) {
	h := &Handler{bucket: "reliquary"}
	uri := "/storage/reliquary/files/alice/2026/06/report.pdf?X-Amz-Signature=xyz"
	req := httptest.NewRequest(http.MethodGet, "/api/auth/check", nil)
	req.Header.Set("X-Forwarded-Uri", uri)
	res := httptest.NewRecorder()
	auth.NoAuthMiddleware("alice")(http.HandlerFunc(h.AuthCheck)).ServeHTTP(res, req)

	if res.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204 (body %s)", res.Code, res.Body.String())
	}
}

func TestAuthCheckDeniesOtherUsersKeys(t *testing.T) {
	h := &Handler{bucket: "reliquary"}
	req := httptest.NewRequest(http.MethodGet, "/api/auth/check", nil)
	req.Header.Set("X-Forwarded-Uri", "/storage/reliquary/files/bob/2026/06/report.pdf")
	res := httptest.NewRecorder()
	auth.NoAuthMiddleware("alice")(http.HandlerFunc(h.AuthCheck)).ServeHTTP(res, req)

	if res.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", res.Code)
	}
}

func TestAuthCheckRejectsMissingForwardedURI(t *testing.T) {
	h := &Handler{bucket: "reliquary"}
	req := httptest.NewRequest(http.MethodGet, "/api/auth/check", nil)
	res := httptest.NewRecorder()
	auth.NoAuthMiddleware("alice")(http.HandlerFunc(h.AuthCheck)).ServeHTTP(res, req)

	if res.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", res.Code)
	}
}

func TestAuthCheckDeniesAnonymous(t *testing.T) {
	h := &Handler{bucket: "reliquary"}
	req := httptest.NewRequest(http.MethodGet, "/api/auth/check", nil)
	req.Header.Set("X-Forwarded-Uri", "/storage/reliquary/files/alice/2026/06/report.pdf")
	res := httptest.NewRecorder()
	h.AuthCheck(res, req)

	if res.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", res.Code)
	}
}

func TestEmitCreateUsesCanonicalS3Metadata(t *testing.T) {
	emitter := &fakeEmitter{}
	modified := time.Date(2026, 6, 15, 12, 0, 0, 0, time.FixedZone("MYT", 8*60*60))
	h := &Handler{
		store:      &fakeFileStore{stat: minio.ObjectInfo{Size: 204800, LastModified: modified}},
		events:     emitter,
		deviceName: "reliquary",
	}

	err := h.emitCreate(
		context.Background(),
		"files/alice/2026/06/report.pdf",
		"abcdef123456",
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(emitter.events) != 1 {
		t.Fatalf("got %d events, want 1", len(emitter.events))
	}
	got := emitter.events[0]
	if got.Event != event.Create ||
		got.FilePath != "files/alice/2026/06/report.pdf" ||
		got.Filename != "report.pdf" ||
		got.Size != 204800 ||
		got.Hash != "sha256:abcdef123456" ||
		got.Mtime != "2026-06-15T04:00:00Z" ||
		got.StorageType != event.StorageS3 {
		t.Fatalf("unexpected event: %+v", got)
	}
}

func TestEmitCreatePropagatesPublisherFailure(t *testing.T) {
	publishErr := errors.New("broker unavailable")
	h := &Handler{
		store: &fakeFileStore{stat: minio.ObjectInfo{
			Size:         1,
			LastModified: time.Now(),
		}},
		events:     &fakeEmitter{err: publishErr},
		deviceName: "reliquary",
	}

	err := h.emitCreate(context.Background(), "files/alice/a.txt", "abc")
	if !errors.Is(err, publishErr) {
		t.Fatalf("got %v, want %v", err, publishErr)
	}
}

func TestEmitDeleteUsesCanonicalMinimalEvent(t *testing.T) {
	emitter := &fakeEmitter{}
	h := &Handler{events: emitter, deviceName: "reliquary"}

	if err := h.emitDelete(context.Background(), "files/alice/report.pdf"); err != nil {
		t.Fatal(err)
	}
	got := emitter.events[0]
	if got.Event != event.Delete ||
		got.FilePath != "files/alice/report.pdf" ||
		got.Filename != "report.pdf" ||
		got.Size != 0 ||
		got.Hash != "" ||
		got.Mtime != "" {
		t.Fatalf("unexpected event: %+v", got)
	}
}

func TestUploadStoresBeforePublishing(t *testing.T) {
	var order []string
	store := &recordingFileStore{objects: make(map[string]minio.ObjectInfo), order: &order}
	emitter := &fakeEmitter{order: &order}
	thumbs := &fakeThumbnailPublisher{order: &order}
	h := &Handler{
		store:      store,
		files:      &fakeFileIndex{order: &order},
		thumbs:     thumbs,
		checksums:  &fakeChecksumIndex{existing: make(map[string]string), order: &order},
		events:     emitter,
		deviceName: "reliquary",
	}

	req := multipartUploadRequest(t, "report.png", "image/png", []byte("hello"))
	res := httptest.NewRecorder()
	auth.NoAuthMiddleware("alice")(http.HandlerFunc(h.Upload)).ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
	}
	gotOrder := strings.Join(order, ",")
	if gotOrder != "storage:put,checksum:add,file-index:upsert,thumbnail:publish,emit:create" {
		t.Fatalf("unexpected operation order: %s", gotOrder)
	}
	if len(thumbs.jobs) != 1 ||
		thumbs.jobs[0].Version != thumbnail.JobVersion ||
		thumbs.jobs[0].ContentType != "image/png" ||
		thumbs.jobs[0].Checksum == "" {
		t.Fatalf("unexpected thumbnail jobs: %+v", thumbs.jobs)
	}
}

func TestUploadReturnsServiceUnavailableAfterPublishFailure(t *testing.T) {
	publishErr := errors.New("broker unavailable")
	store := &recordingFileStore{objects: make(map[string]minio.ObjectInfo)}
	h := &Handler{
		store:      store,
		files:      &fakeFileIndex{},
		thumbs:     &fakeThumbnailPublisher{},
		checksums:  &fakeChecksumIndex{existing: make(map[string]string)},
		events:     &fakeEmitter{err: publishErr},
		deviceName: "reliquary",
	}

	req := multipartUploadRequest(t, "report.txt", "text/plain", []byte("hello"))
	res := httptest.NewRecorder()
	auth.NoAuthMiddleware("alice")(http.HandlerFunc(h.Upload)).ServeHTTP(res, req)

	if res.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
	}
	if len(store.objects) != 1 {
		t.Fatalf("stored objects=%d, want 1", len(store.objects))
	}
}

func TestDuplicateUploadRepublishesCreate(t *testing.T) {
	data := []byte("hello")
	sum := sha256.Sum256(data)
	checksum := hex.EncodeToString(sum[:])
	existingKey := "files/alice/2026/06/report.txt"
	emitter := &fakeEmitter{}
	store := &recordingFileStore{objects: map[string]minio.ObjectInfo{
		existingKey: {
			Key:          existingKey,
			Size:         int64(len(data)),
			LastModified: time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC),
			ContentType:  "image/png",
		},
	}}
	thumbs := &fakeThumbnailPublisher{}
	h := &Handler{
		store:      store,
		thumbs:     thumbs,
		checksums:  &fakeChecksumIndex{existing: map[string]string{checksum: existingKey}},
		events:     emitter,
		deviceName: "reliquary",
	}

	req := multipartUploadRequest(t, "report.png", "image/png", data)
	res := httptest.NewRecorder()
	auth.NoAuthMiddleware("alice")(http.HandlerFunc(h.Upload)).ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
	}
	if len(emitter.events) != 1 || emitter.events[0].FilePath != existingKey {
		t.Fatalf("unexpected events: %+v", emitter.events)
	}
	if len(thumbs.jobs) != 1 || thumbs.jobs[0].FileKey != existingKey {
		t.Fatalf("unexpected thumbnail jobs: %+v", thumbs.jobs)
	}
}

func TestUploadSucceedsAfterThumbnailPublishFailure(t *testing.T) {
	store := &recordingFileStore{objects: make(map[string]minio.ObjectInfo)}
	emitter := &fakeEmitter{}
	h := &Handler{
		store:      store,
		files:      &fakeFileIndex{},
		thumbs:     &fakeThumbnailPublisher{err: errors.New("thumbnail broker unavailable")},
		checksums:  &fakeChecksumIndex{existing: make(map[string]string)},
		events:     emitter,
		deviceName: "reliquary",
	}

	req := multipartUploadRequest(t, "report.png", "image/png", []byte("hello"))
	res := httptest.NewRecorder()
	auth.NoAuthMiddleware("alice")(http.HandlerFunc(h.Upload)).ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
	}
	if len(store.objects) != 1 {
		t.Fatalf("stored objects=%d, want 1", len(store.objects))
	}
	if len(emitter.events) != 1 {
		t.Fatalf("create event not published after thumbnail failure: %+v", emitter.events)
	}
	var got UploadResponse
	if err := json.NewDecoder(res.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.Warning == "" {
		t.Fatalf("warning is empty: %+v", got)
	}
}

func TestListFilesRepairsMissingManifest(t *testing.T) {
	files := &fakeFileIndex{
		err: storage.ErrFileIndexNotFound,
		manifest: storage.FileManifest{Files: []storage.FileIndexItem{
			{
				Key:          "files/alice/2026/06/report.txt",
				Size:         12,
				ContentType:  "text/plain",
				LastModified: time.Date(2026, 6, 19, 10, 0, 0, 0, time.UTC),
			},
		}},
	}
	h := &Handler{files: files}

	req := httptest.NewRequest(http.MethodGet, "/api/files", nil)
	res := httptest.NewRecorder()
	auth.NoAuthMiddleware("alice")(http.HandlerFunc(h.ListFiles)).ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
	}
	if files.rebuilds != 1 {
		t.Fatalf("rebuilds=%d, want 1", files.rebuilds)
	}
	var got FileListResponse
	if err := json.NewDecoder(res.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.TotalCount != 1 || len(got.Files) != 1 || got.Files[0].Key != "files/alice/2026/06/report.txt" {
		t.Fatalf("unexpected response: %+v", got)
	}
}

func TestDeleteRemovesBeforePublishing(t *testing.T) {
	var order []string
	key := "files/alice/report.txt"
	store := &recordingFileStore{
		objects: map[string]minio.ObjectInfo{key: {Key: key}},
		order:   &order,
	}
	h := &Handler{
		store:      store,
		files:      &fakeFileIndex{order: &order},
		checksums:  &fakeChecksumIndex{order: &order},
		events:     &fakeEmitter{order: &order},
		deviceName: "reliquary",
	}

	req := httptest.NewRequest(http.MethodDelete, "/api/files?key="+url.QueryEscape(key), nil)
	res := httptest.NewRecorder()
	auth.NoAuthMiddleware("alice")(http.HandlerFunc(h.DeleteFile)).ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.Code, res.Body.String())
	}
	gotOrder := strings.Join(order, ",")
	if gotOrder != "storage:delete,checksum:remove,storage:delete,file-index:remove,emit:delete" {
		t.Fatalf("unexpected operation order: %s", gotOrder)
	}
}

func multipartUploadRequest(
	t *testing.T,
	filename string,
	contentType string,
	data []byte,
) *http.Request {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/upload", &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	// multipart.CreateFormFile defaults to application/octet-stream. Replace
	// the part header content type for handler behavior tests.
	raw := strings.Replace(
		body.String(),
		"Content-Type: application/octet-stream",
		"Content-Type: "+contentType,
		1,
	)
	req = httptest.NewRequest(http.MethodPost, "/api/upload", strings.NewReader(raw))
	req.Header.Set("Content-Type", writer.FormDataContentType())
	return req
}
