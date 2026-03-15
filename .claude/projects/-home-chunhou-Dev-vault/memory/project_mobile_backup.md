---
name: Mobile backup and USB OTG architecture
description: Architecture notes for mobile offline backup, USB OTG direct write, and multi-device scenarios
type: project
---

Core constraint: phones have insufficient storage, so local staging is not viable. Files must leave the device immediately.

**Viable backup paths (no server available):**
- **USB OTG (Android)** — write directly to USB drive, delete local copy. One phone at a time. iOS does not support this well.
- **LAN server** — upload to a laptop/NAS/other phone running Reliquary. Already supported via configurable server endpoint.
- **Phone-to-phone** — one phone with more space acts as temporary server for the other.

**Multi-device USB scenario (2 phones, 1 drive):**
- Sequential use — first phone connects, offloads, disconnects. Second phone does the same.
- No sync protocol needed. Each phone writes to the drive directly.
- Deduplication by SHA-256 checksum at server import handles overlapping files.
- Filename collisions handled by existing `_1`, `_2` suffix logic.

**Server-side bulk import needed:**
- CLI or API endpoint to ingest a directory of files from a mounted USB drive into MinIO.
- Computes checksums, skips duplicates, generates thumbnails.

**External storage access (both platforms):**
- Neither Android nor iOS allows auto-detecting a specific directory on a USB drive without user interaction.
- Both require the user to pick a folder via a system directory picker at least once.
- Android: persist permission via `takePersistableUriPermission` — survives app restarts.
- iOS: persist access via security-scoped bookmarks — same effect.
- Practical UX: one-time-per-drive setup. User picks or creates `reliquary/` folder on first plug-in. App remembers it for subsequent connections.

**iOS USB drive notes:**
- iOS 13+ supports USB drives through the Files app / document picker API.
- No direct filesystem path — access is via security-scoped URLs with file coordination APIs.
- If app is backgrounded mid-transfer, iOS may suspend it. User must stay in-app during large transfers.
- File provider framework adds some overhead vs Android's direct I/O.
- Background uploads limited to ~30s via BGProcessingTask.
- Workable but more friction than Android.

**Why:** The phone's storage is the bottleneck — Reliquary exists to free space immediately, not stage files for later.
**How to apply:** Don't design features that require local staging. Prioritize direct-to-destination upload paths. USB OTG and external storage features are later-stage implementation.
