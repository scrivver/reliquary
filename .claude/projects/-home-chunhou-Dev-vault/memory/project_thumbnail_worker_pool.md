---
name: Thumbnail worker pool needed
description: Unbounded goroutines for thumbnail generation can spike memory/CPU on batch uploads
type: project
---

Currently thumbnail generation spawns a new goroutine per upload with no concurrency limit. With large batch uploads (hundreds of files), this can spike memory (images decoded in-memory), saturate CPU (resizing + ffmpeg), and overwhelm MinIO with concurrent reads.

**Fix:** Replace unbounded `go func()` with a bounded worker pool (e.g. 4 concurrent workers). Uploads push to a channel, workers drain it in order.

**Why:** Batch uploads of hundreds of files can destabilize the backend.
**How to apply:** Implement a thumbnail job queue with configurable concurrency (e.g. `THUMBNAIL_WORKERS` env var, default 4). Apply to both image and video thumbnail generation.
