# Explicit Storage Event Publication

Status: implemented.

## Goal

Make the Reliquary backend the authoritative event producer for every user-visible
S3 mutation. Remove Reliquary's dependency on MinIO bucket notifications while
preserving Engram's existing filesystem watcher message as the canonical contract.

Reliquary currently has only a MinIO/S3 backend. It has no filesystem storage
implementation or watcher.

## Canonical Message

Publish persistent JSON messages to `engram.ingest`:

```json
{
  "event": "create",
  "file_path": "files/alice/2026/06/report.pdf",
  "filename": "report.pdf",
  "size": 204800,
  "hash": "sha256:abcdef123456",
  "mtime": "2026-06-15T12:00:00Z",
  "device_name": "reliquary",
  "storage_type": "s3"
}
```

Field names and event values must match `engram/watcher/internal/publisher.FileEvent`.
For S3, `file_path` is the object key, `hash` is the SHA-256 checksum with the
`sha256:` prefix, and `mtime` is UTC RFC3339. Delete events may omit unavailable
size, hash, and modification fields. Reserve `old_file_path` for a future rename.

## Backend Design

1. Add `backend/event` with `FileEvent` and an `Emitter` interface. Keep HTTP
   handlers dependent on the interface, not RabbitMQ.
2. Add a RabbitMQ emitter using persistent delivery, publisher confirms, and
   unroutable-message detection. Queue topology remains infrastructure-owned.
3. Configure it with `RABBITMQ_URL`, `EVENT_QUEUE` (default `engram.ingest`), and
   `EVENT_DEVICE_NAME` (default `reliquary`). Disabling events must require an
   explicit standalone setting and emit a startup warning.
4. Construct and close the emitter in `backend/main.go`; fail startup when events
   are required but RabbitMQ is unavailable.
5. Inject the emitter into `handler.Handler`.

## Operation Semantics

- **Upload:** after `PutObject` succeeds, stat the object and publish `create`.
  Use the upload checksum, stored key basename, authoritative size, and timestamp.
- **Duplicate upload:** re-publish `create` for the existing object. This makes a
  retry recover from an earlier publish failure; Engram must tolerate duplicates.
- **Delete:** after removing the object, publish `delete` for the active file key.
- Do not emit for thumbnails, checksum indexes, user records, reads, presigning,
  failed mutations, or objects outside `files/`.
- After archival removal, there are no archive move events. A future rename API
  should publish one `rename` event rather than a create/delete pair.

S3 and RabbitMQ are not transactional. If storage succeeds but broker confirmation
fails, return `503 Service Unavailable`. Retrying the idempotent request must
re-publish the event. Document delivery as **at least once**, and make Engram's
create handling idempotent by object path.

## Infrastructure Migration

1. Remove `MINIO_NOTIFY_AMQP_*` configuration and `mc event add` from the integrated
   root infrastructure.
2. Add RabbitMQ to Reliquary's standalone development/deployment configuration.
3. Deploy explicit publication and disable MinIO notifications together to avoid
   duplicate events.
4. Keep Engram's legacy S3-notification parser temporarily for compatibility, then
   remove it after all producers use the canonical format.

## Filesystem and Synapse Boundary

Engram's standalone Go watcher is the filesystem event producer. It recursively
watches configured directories with `fsnotify` and emits create, delete, and rename
events. Synapse has no watcher: its filesystem mover performs explicit moves and
emits a separate `MoveCompleted` domain event, currently non-fatal if publication
fails.

If Reliquary later gains filesystem storage, choose exactly one producer per path:
explicit backend events or the Engram watcher. Never enable both.

## Verification

- Unit-test event payloads, upload/delete ordering, duplicate retries, and publish
  failures with a fake emitter.
- Integration-test RabbitMQ confirmation and Engram ingestion for create/delete.
- Confirm MinIO has no notification target or bucket event rule.
- Confirm one upload produces one indexed Engram record and deletion removes it.
- `go test ./...` passes in `backend/`.
