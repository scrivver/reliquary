# File Index Manifest Plan

## Problem

The file explorer currently loads files through `GET /api/files`, but the
backend implements that endpoint by listing the user's object-storage prefix.

For R2 and other S3-compatible providers, list operations can be expensive
Class A operations. The current backend also slices pagination after listing the
full prefix, so multiple frontend pages can trigger repeated full listings.

Search and sort are already frontend-only after files are loaded. The expensive
part is the backend list operation used to build the initial file list.

## Goal

Normal file explorer loads should not call object-storage `ListObjects`.

Instead, Reliquary should maintain a durable per-user file manifest and use that
manifest as the source for file listing, pagination, search-ready metadata, and
stats.

## Non-Goals

- Do not add Redis in the first implementation.
- Do not add a database.
- Do not change the frontend API contract unless needed.
- Do not make thumbnail generation critical to upload success.
- Do not rely on object-storage listing after a manifest exists.

## Manifest Location

Store one manifest object per user:

```text
indexes/{username}/files.json
```

This keeps the index in the same object store as the data and avoids requiring
new infrastructure.

## Manifest Shape

Initial schema:

```json
{
  "version": 1,
  "updated_at": "2026-06-19T10:00:00Z",
  "files": [
    {
      "key": "files/alice/2026/06/photo.jpg",
      "size": 12345,
      "content_type": "image/jpeg",
      "last_modified": "2026-06-19T10:00:00Z",
      "checksum": "sha256...",
      "upload_date": "2026-06-19T10:00:00Z",
      "original_name": "photo.jpg"
    }
  ]
}
```

The file entry should contain the fields needed by `FileItem` so listing does
not need a per-file `StatObject` call.

## Backend Service

Add a backend service, likely under `backend/storage/file_index.go`, with
methods similar to:

```go
type FileIndex struct {
    store *Client
}

func (idx *FileIndex) Load(ctx context.Context, username string) (FileManifest, error)
func (idx *FileIndex) Upsert(ctx context.Context, username string, item FileIndexItem) error
func (idx *FileIndex) Remove(ctx context.Context, username, key string) error
func (idx *FileIndex) DeleteUser(ctx context.Context, username string) error
func (idx *FileIndex) Rebuild(ctx context.Context, username string) (FileManifest, error)
```

The service should own manifest serialization and object key naming.

## Read Flow

`GET /api/files` should become:

```text
load indexes/{user}/files.json
sort by stable default order
apply offset/limit
return FileListResponse
```

The first implementation can preserve the existing frontend behavior by keeping
the same response shape:

```json
{
  "files": [],
  "total_count": 0,
  "offset": 0,
  "limit": 50
}
```

## Upload Flow

After the object is stored and checksum metadata is recorded, update the
manifest:

```text
PutObject files/{user}/...
Update checksum index
Upsert manifest entry
Publish thumbnail/event background work
Return upload response
```

Thumbnail publication should remain non-critical. If thumbnail publishing
fails, the uploaded file should still exist in the manifest and the response can
carry a warning.

Duplicate upload behavior should not create another manifest entry unless a new
object is actually written.

## Delete Flow

After deleting the active object and thumbnail, remove the manifest entry:

```text
DeleteObject files/{user}/...
DeleteObject thumbs/{user}/... if present
Remove checksum entry
Remove manifest entry
Return delete response
```

If object deletion succeeds but manifest update fails, the backend should log
the inconsistency clearly. A rebuild command will be the repair mechanism.

## Stats Flow

`GET /api/stats` should compute totals from the manifest instead of listing
objects.

`GET /api/admin/stats` can load each user's manifest and aggregate the results.

## Permanent User Delete

Permanent deletion of a deactivated user should delete:

```text
files/{username}/
thumbs/{username}/
archive/{username}/
archive-thumbs/{username}/
{username}/checksums.json
indexes/{username}/files.json
```

The prefix deletes may still use `ListObjects` because permanent deletion is an
explicit destructive maintenance action, not normal file explorer browsing.

## Rebuild Command

Add a command for existing data and repair:

```bash
go run ./cmd/rebuild-file-index --username alice
go run ./cmd/rebuild-file-index --all
```

The rebuild command is allowed to call `ListObjects`. It should:

1. List `files/{username}/`.
2. Read object metadata needed for each manifest entry.
3. Write `indexes/{username}/files.json`.
4. Report the number of indexed objects.

For R2-conscious deployments, rebuild should be run explicitly after large
imports or migrations so the first user request does not pay that cost.

## Missing Manifest Behavior

For the first implementation, `/api/files` can repair a missing manifest by
running a one-time rebuild from object storage.

Recommended behavior:

```text
load manifest
if missing: rebuild from files/{user}/
serve response from rebuilt manifest
```

Development and deployment docs should still expose the rebuild CLI so admins
can prebuild indexes after importing existing data.

## Concurrency

The first implementation can use simple read-modify-write because the current
deployment model already cautions against relying on multiple API replicas for
heavy concurrent writes.

Known risk:

```text
upload A reads manifest
upload B reads manifest
upload A writes manifest
upload B writes manifest
upload A entry is lost
```

Future improvement:

```text
read manifest with ETag
apply mutation
write only if ETag is unchanged
retry on conflict
```

This should be evaluated against both MinIO and R2 support through the Go MinIO
client before implementation.

## Migration Steps

1. Add `FileIndex` types and tests.
2. Add manifest read/write helpers to the storage layer.
3. Add rebuild CLI command.
4. Update upload to upsert manifest entries.
5. Update delete to remove manifest entries.
6. Update `/api/files` to read from the manifest.
7. Update `/api/stats` and `/api/admin/stats` to use manifests.
8. Create empty manifests when local users are created.
9. Update permanent user deletion to remove the manifest object.
10. Document the rebuild command in `docs/development.md` or
   `docs/deployment.md`.

## Acceptance Criteria

- Opening the file explorer does not call object-storage `ListObjects`.
- Loading additional frontend pages does not call `ListObjects`.
- Search and sort continue to work from the loaded file list.
- Uploads appear in the file explorer after the manifest update.
- Deleted files disappear from the file explorer after the manifest update.
- Stats reflect manifest contents.
- Existing installations can run a rebuild command to create manifests.
- Missing manifests are repaired once and future reads use the manifest.
