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
| `PUT` | `/api/users/me/password` | Yes | Change your own password; requires the current password |
| `GET` | `/api/admin/stats` | Admin | Aggregate analytics |
| `POST` | `/api/admin/users` | Admin | Create standard user |
| `GET` | `/api/admin/users` | Admin | List users |
| `DELETE` | `/api/admin/users/{username}` | Admin | Deactivate standard user |
| `DELETE` | `/api/admin/users/{username}?permanent=true` | Admin | Permanently delete a deactivated standard user and their data |
| `PUT` | `/api/admin/users/{username}/activate` | Admin | Re-enable a deactivated standard user |
| `PUT` | `/api/admin/users/{username}/password` | Admin | Reset a standard user's password |

## Password Changes

The two paths are separate endpoints with different rules, because they are
different operations:

**Your own password** — `PUT /api/users/me/password`, available to any
authenticated user:

```json
{ "current_password": "...", "new_password": "..." }
```

The current password is required, so a stolen token cannot be escalated into
permanent ownership of the account. A wrong current password returns `403`, not
`401`, so clients do not mistake it for an expired session.

The change signs out every other session for that account. The response carries
a replacement token in the same shape as `/api/login`, keeping the calling
client signed in — store it, or subsequent requests will `401`.

**Someone else's password** — `PUT /api/admin/users/{username}/password`, admin
only:

```json
{ "password": "..." }
```

An admin resets standard users' passwords without knowing the current one. This
endpoint refuses admin accounts, including the caller's own (`403`) and
deactivated accounts (`409`); admins change their own password through the
self-service endpoint like everyone else.

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
