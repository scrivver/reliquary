# Separate Thumbnail Worker

Status: implemented.

## Goal

Remove thumbnail processing from the Reliquary API process. Upload handlers should
publish durable jobs to RabbitMQ, while independently scalable worker processes
generate thumbnails in S3-compatible storage.

This phase does not yet make the API fully horizontally scalable. The S3-backed
checksum and user indexes remain separate follow-up work.

## Current Behavior

`backend/worker/thumbnail.go` owns an in-memory channel with capacity 100. The API
starts worker goroutines in `backend/main.go` and calls `Submit` after an upload.
Jobs are lost on restart and silently dropped when the channel is full. Every API
replica would create another independent worker pool.

## Job Contract

Publish persistent messages to `reliquary.thumbnail`:

```json
{
  "version": 1,
  "file_key": "files/alice/2026/06/report.pdf",
  "content_type": "application/pdf",
  "checksum": "abcdef123456"
}
```

The deterministic destination is derived as
`thumbs/alice/2026/06/report.pdf`. Reject unsupported versions and keys outside
`files/`.

## Backend Changes

1. Add `backend/thumbnail` containing `Job`, `Publisher`, and RabbitMQ adapter.
2. Use persistent delivery, mandatory routing, publisher confirms, and passive
   queue validation, matching the existing Engram event emitter.
3. Replace `*worker.ThumbnailWorker` in `handler.Handler` with a publisher
   interface.
4. After a supported upload succeeds, publish a thumbnail job before returning
   success. Return `503` if storage succeeded but RabbitMQ did not confirm.
5. On duplicate upload, republish both the thumbnail job and canonical create
   event so retries repair either missing side effect.
6. Remove thumbnail worker construction and goroutine startup from the API.

## Worker Binary

Add `backend/cmd/reliquary-thumbnail-worker`:

1. Load S3 and RabbitMQ configuration.
2. Validate the required queue at startup.
3. Consume with manual acknowledgements and configurable bounded prefetch.
4. Reuse the image, video, and PDF generation code from
   `backend/worker/thumbnail.go` as a synchronous processor.
5. Ack successful, unsupported, stale, or source-missing jobs.
6. Retry transient S3 and process failures with a bounded attempt count; route
   exhausted jobs to `reliquary.thumbnail.dead`.
7. Stop consuming on shutdown, finish in-flight work within a grace period, then
   close RabbitMQ and S3 clients.

## Idempotency And Races

- Thumbnail keys remain deterministic, so repeated jobs overwrite the same object.
- Stamp generated thumbnails with the source checksum and skip work when an
  existing thumbnail already has that checksum.
- Before writing, verify that the source object still exists and matches the job
  checksum.
- After writing, verify the source again. If it was deleted or replaced during
  generation, delete the stale thumbnail.
- Deleting a file continues deleting its current thumbnail. Missing objects and
  repeated deletes are successful no-ops.

## Queue Topology

Infrastructure owns durable queues and bindings:

- `reliquary.thumbnail`
- `reliquary.thumbnail.dead`

Use a bounded retry policy with attempt metadata and dead-letter exhausted jobs.
Do not allow immediate unbounded `nack(requeue=true)` loops. Configure:

- `THUMBNAIL_QUEUE` default `reliquary.thumbnail`
- `THUMBNAIL_PREFETCH` default `1`
- `THUMBNAIL_CONCURRENCY` default `4`
- `THUMBNAIL_MAX_ATTEMPTS` default `5`

## Packaging And Development

1. Add the worker binary to the Nix backend package.
2. Add a worker process to standalone and Mind Palace development launchers.
3. Add a separate `reliquary-thumbnail-worker` production image containing
   ffmpeg and Poppler.
4. Remove ffmpeg and Poppler from the eventual API-only image.
5. Keep the all-in-one image by running the API and worker as separate processes
   against the same RabbitMQ and object storage.

## Rollout

1. Deploy queue topology first.
2. Deploy and verify at least one worker consumer.
3. Deploy the API publisher and disable the embedded worker in the same release.
4. Upload image, video, and PDF fixtures and verify one correct thumbnail each.
5. Retry duplicate uploads and verify no duplicate thumbnail objects.
6. Restart workers with queued and in-flight jobs and verify eventual completion.
7. Delete a source during generation and verify no orphan thumbnail remains.

Do not run embedded and queued workers together after cutover.

## Verification Gate

- API tests prove publish ordering, duplicate recovery, and `503` behavior.
- Worker tests cover supported formats, idempotency, stale checks, retries, dead
  lettering, malformed jobs, and graceful shutdown.
- RabbitMQ integration tests cover confirmed publication and manual ack behavior.
- Queue depth survives API and worker restarts.
- Multiple worker replicas process a workload without duplicate thumbnail keys.
- The API process contains no thumbnail goroutines or ffmpeg/Poppler dependency.
- `go test ./...`, `go vet ./...`, Nix package builds, and end-to-end smoke tests
  pass.
