# Canonical File Events

Reliquary publishes canonical file-event messages to `engram.ingest` after it
successfully mutates storage.

| Field | Required | Description |
|---|---|---|
| `event` | yes | `create` or `delete` |
| `file_path` | yes | S3 object key used as storage identity |
| `filename` | yes | Sanitized relative display path presented to users |
| `size` | create | Size in bytes |
| `hash` | create | SHA-256 as `sha256:<hex>` |
| `mtime` | create | UTC RFC3339 timestamp |
| `device_name` | yes | Producer identifier |
| `storage_type` | yes | `s3` |

`filename` is user-facing. For a folder upload such as `docs/myfile.pdf`,
Reliquary emits `filename: "docs/myfile.pdf"`. `file_path` remains the storage
identity, for example `files/alice/2026/07/docs/myfile.pdf`.

Consumers must identify stored files by `(storage_type, file_path)` and handle
repeated messages idempotently. Clients should group or display user folders
from `filename`, not from `file_path`.
