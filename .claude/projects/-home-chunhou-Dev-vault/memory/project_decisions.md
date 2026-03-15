---
name: Technical decisions
description: Key technical decisions for Reliquary - architecture, auth, storage, targets
type: project
---

Technical decisions as of 2026-03-15:

- **Router**: `chi` for Go backend routing and middleware
- **General file storage**: Supports all file formats. Thumbnails for images (resize) and videos (ffmpeg). MinIO path is `{username}/files/YYYY/MM/`
- **Folder structure**: Use upload date (not EXIF) for YYYY/MM paths
- **Auth**: Multi-user with bcrypt, stored as JSON in MinIO. Admin/user roles. JWT includes username+role
- **Primary targets**: Web, Android, iOS (iOS testing deferred). Desktop (Windows, Linux, macOS) to be confirmed later
- **Thumbnails**: ~300px width, JPEG quality 80, bounded worker pool (default 4 workers)
- **Deduplication**: SHA-256 checksum on upload, per-user checksum index in MinIO
- **Lifecycle archival**: Files older than ARCHIVE_AFTER_DAYS (default 90) auto-moved to archive prefix
- **No external database**: All state in MinIO (user store, checksum indexes, file metadata as object metadata)
- **Reverse proxy**: Caddy at port 2080, single origin for frontend/backend/MinIO
- **MinIO credentials**: `minioadmin/minioadmin`, bucket `smartaffiliate`

**Why:** Keep infrastructure minimal (just MinIO) while supporting multi-user, dedup, and archival.
**How to apply:** All persistent state lives in MinIO. No SQLite or external DB unless query complexity demands it.
