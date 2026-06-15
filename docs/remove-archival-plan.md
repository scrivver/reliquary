# Remove Lifecycle Archival

Status: implemented.

## Goal

Remove lifecycle archival from the active Reliquary product. Files must remain under
`files/<user>/...` until explicitly deleted. Keep the archival worker source as a
dormant stub for reference, but do not construct, schedule, or expose any path that
can trigger it.

## Scope

### Backend

1. Stop constructing `worker.ArchivalWorker` in `backend/main.go` and remove the
   startup goroutine that calls `Start`.
2. Unregister all `/api/archive` routes, including the manual `/api/archive/run`
   trigger.
3. Remove the archival dependency from `handler.Handler` and its constructor.
4. Remove archive handlers from `backend/handler/handler.go`. Retain
   `backend/worker/archival.go` as unreferenced stub code with a package comment
   stating that the feature is disabled.
5. Remove `ARCHIVE_AFTER_DAYS` and `ARCHIVE_CHECK_HOURS` from active configuration.
6. Simplify storage statistics to report active files only. Remove
   `archive_count` and `archive_size` from `UserStats`.
7. Narrow ownership checks to active `files/` and `thumbs/` namespaces.

### Frontend

1. Remove the Archive destination and `ArchiveScreen` from `app_shell.dart`.
2. Delete `archive_screen.dart` and archive methods from `ApiService`.
3. Remove archived-file cards and totals from `stats_screen.dart`; total storage
   should equal active file storage.
4. Update widget tests for the new navigation order and stats response.

### Documentation

Remove archival claims, endpoints, and environment variables from `README.md` and
`CLAUDE.md`. Keep references to archive file formats such as ZIP; those are unrelated.

## Existing Archived Data

Before removing restore access, add a one-time operator command that moves:

- `archive/<user>/...` to `files/<user>/...`
- `archive-thumbs/<user>/...` to `thumbs/<user>/...`

The command must avoid overwriting active keys and report conflicts. Run it before
deploying the UI/API removal. Do not automatically migrate data during normal backend
startup.

Use `go run ./cmd/restore-archive` from `backend/` for a dry-run and add `-apply`
to perform the migration. Packaged deployments expose the same command as
`restore-archive`.

## Verification

- `go test ./...` passes in `backend/`.
- `flutter analyze` and `flutter test` pass in `frontend/`.
- Backend startup logs contain no archival worker activity.
- `/api/archive` and `/api/archive/run` return `404`.
- Navigation contains Files, Status, optional Users, and Config only.
- Uploading files and waiting beyond the former thresholds never moves objects out
  of `files/<user>/...`.
