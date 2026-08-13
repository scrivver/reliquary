# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Reliquary is a self-hosted cold storage system built with Nix flakes. The Go
backend stores objects in MinIO and explicitly publishes canonical file events
to RabbitMQ for Engram ingestion.

## Development Environment

The project provides multiple dev shells via `flake.nix`:

```bash
nix develop              # Full shell (backend + frontend + infra)
nix develop .#backend    # Backend shell (Go + infra)
nix develop .#frontend   # Frontend shell (Flutter + infra)
nix develop .#infra      # Infra only (MinIO + RabbitMQ + process-compose)
```

The shell hook automatically:
- Generates `process-compose.yaml` and `dev-process-compose.yaml` in `.data/`
- Exports `DATA_DIR`, `PC_SOCKET`, `MINIO_PORT_FILE`, `MINIO_CONSOLE_PORT_FILE`, `PROXY_PORT_FILE`
- Adds `bin/` to PATH

## Infrastructure Commands

```bash
dev                      # Start the full local stack via process-compose
start-infra              # Start MinIO + RabbitMQ + Caddy via process-compose
source load-infra-env    # Export MinIO, RabbitMQ, and proxy settings
start-backend            # Start backend with hot reload in the current terminal
start-frontend           # Start Flutter web server in the current terminal
shutdown-infra           # Stop process-compose services
```

## Architecture

- **`flake.nix`** — Dev shell definitions. Imports shell modules from `shells/` and generates infra-only and full-stack process-compose configs at nix eval time using `pkgs.formats.yaml`.
- **`shells/`** — Nix shell definitions. `infra.nix` is the base shell; `backend.nix` and `frontend.nix` extend it via `inputsFrom`.
- **`backend/`** — Go API server (chi router, JWT auth, multipart upload, thumbnail generation).
  - `config/` — Environment-based configuration (MinIO, auth, JWT, worker pool).
  - `event/` — Canonical `FileEvent` contract and confirmed RabbitMQ emitter.
  - `auth/` — JWT login handler, auth middleware, admin middleware, and user store (JSON in MinIO with bcrypt).
  - `handler/` — HTTP handlers for upload, file listing, presigned download, deletion, user admin, and storage analytics.
  - `storage/` — MinIO client wrapper (put, get, list, delete, presign, stat, copy, move). Per-user checksum index, storage stats, and one-time migrations.
  - `worker/` — Thumbnail generation (bounded worker pool, image resize + ffmpeg video frame extraction).
  - `cmd/restore-archive/` — conflict-safe one-time migration for data archived by older releases.
- **`frontend/`** — Flutter application (web, Android, iOS, Linux desktop targets).
  - `lib/config.dart` — API base URL configuration (persisted, configurable at runtime).
  - `lib/models/` — Data models (FileItem with content type, checksum, metadata).
  - `lib/services/` — Auth service (JWT + username/role + shared_preferences), API service (Dio + multipart upload + presigned URL + preview byte caching + admin/stats API), and platform file picker (custom HTML implementation for web, file_picker for native).
  - `lib/screens/` — Login (with server config), gallery (thumbnail grid + full-res viewer + download + file menu), upload (multi-file with progress + duplicate detection), stats (analytics dashboard), admin (user management), settings (server URL + password change). Responsive navigation: bottom bar on mobile, sidebar on desktop.
- **`infra/minio.nix`** — Defines MinIO process-compose processes as a Nix attrset. Uses ephemeral ports (allocated via Python at runtime) and writes them to `$DATA_DIR/minio/port` and `$DATA_DIR/minio/console_port`. Includes a `minio-create-bucket` process that depends on MinIO being healthy.
- **`infra/rabbitmq.nix`** — Declares the durable `engram.ingest` queue and direct-exchange binding.
- **`infra/caddy.nix`** — Caddy reverse proxy process. Routes `/api/*` to the Go backend (unix socket) and `/storage/*` to MinIO. Handles CORS and strips duplicate MinIO CORS headers. Listens on port 2080 by default.
- **`bin/`** — Shell scripts injected into PATH by the dev shell. Includes `dev` (full process-compose stack), `start-backend`, `start-frontend`, `start-infra`, `load-infra-env`, `shutdown-infra`.
- **`.data/`** — Runtime directory (gitignored). Holds generated configs, MinIO data, Caddy config, port files, and the process-compose unix socket.

## Backend API

All endpoints except `/api/login` and `/api/health` require a `Bearer` JWT token in the `Authorization` header. JWT includes username and role (admin/user).

### Files

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/login` | Authenticate, returns JWT with username and role |
| GET | `/api/health` | Health check |
| POST | `/api/upload` | Multipart file upload (field: `file`), dedup by SHA-256, triggers thumbnail generation |
| GET | `/api/files?offset=0&limit=50` | List user's files (paginated, includes metadata) |
| GET | `/api/files/presign?key=...&download=true` | Presigned download URL (relative path, `download=true` forces content-disposition attachment) |
| GET | `/api/auth/check` | Edge auth check for `/storage/*`: verifies JWT/identity and that the requested key is owned by the caller (called by Caddy `forward_auth`, not by the app) |
| DELETE | `/api/files?key=...` | Delete file, thumbnail, and checksum index entry |

### Analytics & Admin

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/stats` | Storage analytics for current user |
| GET | `/api/admin/stats` | Aggregate analytics across all users (admin only) |
| POST | `/api/admin/users` | Create user (admin only) |
| GET | `/api/admin/users` | List users (admin only) |
| DELETE | `/api/admin/users/{username}` | Delete user (admin only) |
| PUT | `/api/admin/users/{username}/password` | Reset a standard user's password (admin only; refuses admin and deactivated accounts) |
| PUT | `/api/users/me/password` | Change your own password (any authenticated user; requires the current password, returns a replacement token) |

## Running Locally

```bash
# Quick start
nix develop
dev

# Or manually:
start-infra
source load-infra-env
LISTEN_ADDR=$DATA_DIR/backend.sock air    # in backend/
flutter run -d web-server                  # in frontend/
```

All traffic goes through the Caddy proxy at `http://localhost:2080`:
- `/api/*` → Go backend (unix socket at `$DATA_DIR/backend.sock`)
- `/storage/*` → Caddy runs `forward_auth` against `/api/auth/check`, then rewrites to MinIO (presigned download URLs are rewritten to this path)

Default auth credentials: `admin` / `admin` (configurable via `AUTH_USERNAME` and `AUTH_PASSWORD` env vars). First startup seeds the admin user automatically.

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `LISTEN_ADDR` | `:8080` | Backend listen address (path = unix socket) |
| `AUTH_MODE` | `full` | Auth mode: `full` (JWT), `proxy` (verified header), `none` (single user) |
| `AUTH_USERNAME` | `admin` | Initial admin username / default user for none mode |
| `AUTH_PASSWORD` | `admin` | Initial admin password (full mode only) |
| `JWT_SECRET` | `reliquary-dev-secret-change-me` | JWT signing secret (full mode only) |
| `AUTH_PROXY_SHARED_SECRET` | — | Secret the upstream proxy must send as `X-Reliquary-Proxy-Secret` (required in proxy mode) |
| `AUTH_PROXY_INSECURE_TRUST_HEADER` | `false` | Opt out of the shared secret; only for an API reachable solely from the proxy |
| `TRUSTED_PROXIES` | loopback + private ranges | Peers whose `X-Forwarded-For` is believed when rate limiting; empty trusts none |
| `OIDC_ISSUER_URL` | — | OIDC issuer; must match the `iss` claim exactly (oidc mode only) |
| `OIDC_CLIENT_ID` | — | Public PKCE client ID; also the default expected audience |
| `OIDC_AUDIENCE` | `OIDC_CLIENT_ID` | Required `aud` claim on access tokens |
| `OIDC_ALLOW_OPAQUE_TOKENS` | `false` | Accept non-JWT access tokens, which cannot be audience-checked |
| `OIDC_USERNAME_CLAIM` | `preferred_username` | Claim used as the Reliquary username |
| `RABBITMQ_URL` | `amqp://guest:guest@127.0.0.1:5672` | Engram event broker |
| `EVENT_QUEUE` | `engram.ingest` | Predeclared queue and routing key |
| `EVENT_DEVICE_NAME` | `reliquary` | Canonical event producer name |
| `EVENTS_ENABLED` | `true` | Explicit standalone opt-out |
| `THUMBNAIL_QUEUE` | `reliquary.thumbnail` | Durable thumbnail job queue |
| `THUMBNAIL_DEAD_QUEUE` | `reliquary.thumbnail.dead` | Invalid/exhausted jobs |
| `THUMBNAIL_PREFETCH` | `1` | Unacked jobs per worker slot |
| `THUMBNAIL_CONCURRENCY` | `4` | Concurrent jobs per worker process |
| `THUMBNAIL_MAX_ATTEMPTS` | `5` | Attempts before dead-lettering |

## Key Design Decisions

- **Reverse proxy**: Caddy proxies all traffic through a single origin (port 2080), eliminating CORS issues between frontend, backend, and MinIO. Presigned download URLs are rewritten to route through `/storage/*`.
- **Edge download auth**: Presigned URLs alone would let anyone with the link download an object. Caddy's `forward_auth` validates every `/storage/*` request against `/api/auth/check`, which requires a valid JWT/identity and that the caller owns the object key. File bytes still stream MinIO → Caddy → client; the backend only answers a small check request.
- **Unix socket for backend**: The Go backend listens on a unix socket (`$DATA_DIR/backend.sock`) by default when `LISTEN_ADDR` is set to a path. Caddy proxies to it. TCP mode is also supported.
- **Multi-user with app-level auth**: Users managed via JSON file in MinIO (`admin/users.json`) with bcrypt hashing. Each user gets an isolated namespace (`{username}/files/`, `{username}/thumbs/`, etc.). No MinIO IAM — the backend is the single gatekeeper. Usernames are validated against `^[a-zA-Z0-9._-]{1,64}$` before they reach an object key.
- **Revocable sessions**: Every authenticated request re-checks the account behind the JWT, so deactivation, deletion, and role changes apply immediately rather than at token expiry. Password changes and deactivations bump a per-user `token_version` that each token records at login, superseding older tokens. The store is re-read from MinIO every 30s so revocation propagates across API replicas.
- **Deduplication**: SHA-256 checksum computed on upload. Per-user checksum index stored in MinIO. Duplicates return the existing key without re-uploading.
- **Metadata on objects**: Checksum, upload date, and original filename stored as MinIO user metadata (X-Amz-Meta-*). No external database needed.
- **Durable thumbnail generation**: The API publishes confirmed jobs to
  `reliquary.thumbnail`; the standalone worker consumes with manual
  acknowledgements, bounded concurrency, retries, and dead-lettering.
- **Ephemeral ports**: MinIO binds to random available ports to avoid conflicts. Other services discover ports by reading the port files.
- **Nix store paths in process-compose**: Commands in `minio.nix` use `pkgs.writeShellScript`, so the generated YAML references `/nix/store/...` paths directly. The YAML is only valid inside the dev shell.
- **MinIO credentials**: Default dev credentials are `minioadmin/minioadmin`. Default bucket is `reliquary`.
- **Layered dev shells**: Each shell (`infra`, `backend`, `frontend`) composes via `inputsFrom`, so every shell includes infra tooling. The default `full` shell combines backend and frontend.
- **Relative presigned URLs**: Backend returns relative paths (`/storage/...`) for presigned URLs. The frontend fetches preview/download bytes through authenticated requests (Authorization header via Dio), so the browser never opens a raw presigned URL; the edge check requires that header anyway.
- **Custom web file picker**: Flutter's `file_picker` package is unreliable on web. A custom implementation using `HTMLInputElement` directly is used for web; native platforms use `file_picker`.
- **No lifecycle archival**: Active files remain under `files/<user>/...` until explicitly deleted. `backend/worker/archival.go` is a dormant marker only.
- **Legacy archive restoration**: Run `restore-archive` without flags for a dry-run, then with `-apply` after resolving conflicts.
- **Explicit file events**: Reliquary is the sole producer for its S3 mutations.
  Messages are persistent and confirmed, delivery is at least once, and MinIO
  bucket notifications must remain disabled.

## Deployment

The default production-oriented deployment uses separate OCI images:

```bash
# Build Flutter web and load API, thumbnail worker, and ingress images
./bin/deploy
```

Run with docker-compose (or podman compose):

```bash
cp .env.example .env    # Edit with production values
docker compose up -d    # Available at http://localhost:2080
```

### Nix Build Targets

- `nix build .#backend` — API, thumbnail worker, and restore binaries
- `nix build .#frontend-web` — Flutter web static assets
- `nix build .#api-container` — dedicated API image
- `nix build .#thumbnail-worker-container` — dedicated thumbnail worker image
- `nix build .#web-container` — Caddy plus Flutter web image
- `nix build .#ingress-container` — legacy Caddy-only ingress image
- `nix build .#container` — retained all-in-one image

### Container Architecture

The default Compose file separates the Caddy-backed web image, API, thumbnail
worker, MinIO, and RabbitMQ. `minio-init` creates the storage bucket before the
API and worker start. `bin/deploy-all-in-one` and
`docker-compose.all-in-one.yml` preserve the combined deployment.
