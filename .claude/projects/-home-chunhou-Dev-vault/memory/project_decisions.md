---
name: Phase 1 technical decisions
description: Key technical decisions for the Reliquary MVP - router, auth, targets, thumbnails
type: project
---

Phase 1 MVP technical decisions confirmed 2026-03-15:

- **Router**: Using `chi` for Go backend routing and middleware
- **Folder structure**: Use upload date (not EXIF) for YYYY/MM paths
- **Auth**: Hardcoded single-user credentials for MVP. Future: admin frontend for user management
- **Primary targets**: Web, Android, iOS (iOS testing deferred). Desktop (Windows, Linux, macOS) to be confirmed later
- **Thumbnails**: ~300px width, JPEG quality 80, images only (no video for MVP)
- **MinIO credentials**: `minioadmin/minioadmin`, bucket `smartaffiliate` (from infra setup)

**Why:** These simplify the MVP scope while keeping the architecture extensible for Phase 2+.
**How to apply:** Follow these constraints when implementing. Don't over-engineer auth or add EXIF parsing yet.
