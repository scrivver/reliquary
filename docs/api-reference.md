# API Reference

The API is served under `/api`.

## Endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/api/login` | No | Returns JWT token with username and role |
| `GET` | `/api/auth/config` | No | Returns public auth capabilities for the frontend |
| `GET` | `/api/health` | No | Health check |
| `POST` | `/api/upload` | Yes | Multipart file upload with deduplication |
| `GET` | `/api/files?offset=0&limit=50` | Yes | List files with pagination |
| `GET` | `/api/files/presign?key=...&download=true` | Yes | Presigned download URL |
| `GET` | `/api/auth/check` | Yes | Edge check for `/storage/*`: verifies identity and key ownership (invoked by Caddy `forward_auth`, not by the app) |
| `DELETE` | `/api/files?key=...` | Yes | Delete file and thumbnail |
| `GET` | `/api/stats` | Yes | User storage analytics |
| `GET` | `/api/admin/stats` | Admin | Aggregate analytics |
| `POST` | `/api/admin/users` | Admin | Create standard user |
| `GET` | `/api/admin/users` | Admin | List users |
| `DELETE` | `/api/admin/users/{username}` | Admin | Deactivate standard user |
| `DELETE` | `/api/admin/users/{username}?permanent=true` | Admin | Permanently delete a deactivated standard user and their data |
| `PUT` | `/api/admin/users/{username}/activate` | Admin | Re-enable a deactivated standard user |
| `PUT` | `/api/admin/users/{username}/password` | Admin* | Change password |

Admin can change standard-user passwords. Users can change their own passwords.

## File Upload Behavior

Uploads are stored in MinIO and deduplicated by SHA-256 checksum. Uploads and
deletes publish persistent messages after the object storage mutation. Delivery
is at least once.

Thumbnail generation is non-critical background work. If thumbnail publication
fails, the upload can still succeed with a warning.

File listing is served from per-user manifests at
`indexes/{username}/files.json`. Normal `GET /api/files` requests do not call
object-storage `ListObjects`. If a manifest is missing, the API rebuilds it
once from object storage and then serves future requests from the manifest.

## Download Authorization

Presigned URLs are short-lived (15 minutes) but are not a security boundary by
themselves: anyone who possesses one can read the object. Caddy runs a
`forward_auth` check against `/api/auth/check` for every `/storage/*` request
before proxying to MinIO. The check authenticates the request (JWT in
`Authorization`, or whatever the active `AUTH_MODE` uses) and requires that the
requested object key starts with the caller's namespace (`files/<user>/...`,
`thumbs/<user>/...`). Responses: `204` allow, `400` malformed path, `403`
denied. File bytes are never relayed through the Go backend for previews or
single-file downloads; the backend only answers the small check request.

## Admin User Lifecycle

The web/API can create standard users only. Admin users are created during
initialization or with the CLI documented in [Development](development.md).

Standard users follow a two-step removal flow:

1. `DELETE /api/admin/users/{username}` deactivates the user and preserves data.
2. `DELETE /api/admin/users/{username}?permanent=true` deletes an already
   deactivated user and their stored files, thumbnails, and metadata.

Use `PUT /api/admin/users/{username}/activate` to re-enable a deactivated
standard user.

Admin accounts cannot be deleted or re-enabled by another admin through these
endpoints.
