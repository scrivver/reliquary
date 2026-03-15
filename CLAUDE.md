# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Reliquary is a self-hosted cold storage system for forgotten artifacts, built with Nix flakes for reproducibility. The project consists of a Go backend, a Flutter frontend, and MinIO-based infrastructure managed via process-compose. It supports multi-user accounts, file deduplication, automatic lifecycle archival, and video thumbnail generation.

## Development Environment

The project provides multiple dev shells via `flake.nix`:

```bash
nix develop              # Full shell (backend + frontend + infra)
nix develop .#backend    # Backend shell (Go + infra)
nix develop .#frontend   # Frontend shell (Flutter + infra)
nix develop .#infra      # Infra only (MinIO + process-compose)
```

The shell hook automatically:
- Generates `process-compose.yaml` in `.data/` from `infra/minio.nix` and `infra/caddy.nix`
- Exports `DATA_DIR`, `PC_SOCKET`, `MINIO_PORT_FILE`, `MINIO_CONSOLE_PORT_FILE`, `PROXY_PORT_FILE`
- Adds `bin/` to PATH

## Infrastructure Commands

```bash
dev                      # Start all services in tmux (requires tmux)
start-infra              # Start MinIO + Caddy proxy via process-compose (uses unix socket)
source load-infra-env    # Export MINIO_PORT, MINIO_CONSOLE_PORT, PROXY_PORT (must source, not execute)
start-backend            # Start backend with hot reload in tmux window
start-frontend           # Start Flutter web server in tmux window
shutdown-infra           # Stop all services
```

## Architecture

- **`flake.nix`** — Dev shell definitions. Imports shell modules from `shells/` and generates the process-compose config at nix eval time using `pkgs.formats.yaml`.
- **`shells/`** — Nix shell definitions. `infra.nix` is the base shell; `backend.nix` and `frontend.nix` extend it via `inputsFrom`.
- **`backend/`** — Go API server (chi router, JWT auth, multipart upload, thumbnail generation, lifecycle archival).
  - `config/` — Environment-based configuration (MinIO, auth, JWT, lifecycle, worker pool).
  - `auth/` — JWT login handler, auth middleware, admin middleware, and user store (JSON in MinIO with bcrypt).
  - `handler/` — HTTP handlers for upload, file listing, presigned download, deletion, archive management, user admin, and storage analytics.
  - `storage/` — MinIO client wrapper (put, get, list, delete, presign, stat, copy, move). Per-user checksum index. Storage stats computation. Legacy migration.
  - `worker/` — Thumbnail generation (bounded worker pool, image resize + ffmpeg video frame extraction). Lifecycle archival worker (configurable retention).
- **`frontend/`** — Flutter application (web, Android, iOS, Linux desktop targets).
  - `lib/config.dart` — API base URL configuration (persisted, configurable at runtime).
  - `lib/models/` — Data models (FileItem with content type, checksum, metadata).
  - `lib/services/` — Auth service (JWT + username/role + shared_preferences) and API service (Dio + multipart upload + presigned URL caching + admin/archive/stats API).
  - `lib/screens/` — Login, gallery (thumbnail grid + full-res viewer), upload (multi-file with progress), archive (browse/restore/delete), stats (analytics dashboard), admin (user management), settings (server URL + password change).
- **`infra/minio.nix`** — Defines MinIO process-compose processes as a Nix attrset. Uses ephemeral ports (allocated via Python at runtime) and writes them to `$DATA_DIR/minio/port` and `$DATA_DIR/minio/console_port`. Includes a `minio-create-bucket` process that depends on MinIO being healthy.
- **`infra/caddy.nix`** — Caddy reverse proxy process. Routes `/api/*` to the Go backend (unix socket) and `/storage/*` to MinIO. Handles CORS and strips duplicate MinIO CORS headers. Listens on port 2080 by default.
- **`bin/`** — Shell scripts injected into PATH by the dev shell. Includes `dev` (tmux launcher), `start-backend`, `start-frontend`, `start-infra`, `load-infra-env`, `shutdown-infra`.
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
| GET | `/api/files/presign?key=...` | Presigned download URL (routed through proxy) |
| DELETE | `/api/files?key=...` | Delete file, thumbnail, and checksum index entry |

### Archive

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/archive?offset=0&limit=50` | List archived files (paginated) |
| POST | `/api/archive/restore?key=...` | Restore file from archive to active |
| POST | `/api/archive/run` | Trigger archival scan manually |
| DELETE | `/api/archive?key=...` | Permanently delete archived file |

### Analytics & Admin

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/stats` | Storage analytics for current user |
| GET | `/api/admin/stats` | Aggregate analytics across all users (admin only) |
| POST | `/api/admin/users` | Create user (admin only) |
| GET | `/api/admin/users` | List users (admin only) |
| DELETE | `/api/admin/users/{username}` | Delete user (admin only) |
| PUT | `/api/admin/users/{username}/password` | Change password (admin or self) |

## Running Locally

```bash
# Quick start (requires tmux)
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
- `/storage/*` → MinIO (presigned download URLs are rewritten to this path)

Default auth credentials: `admin` / `admin` (configurable via `AUTH_USERNAME` and `AUTH_PASSWORD` env vars). First startup seeds the admin user automatically.

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `LISTEN_ADDR` | `:8080` | Backend listen address (path = unix socket) |
| `AUTH_USERNAME` | `admin` | Initial admin username |
| `AUTH_PASSWORD` | `admin` | Initial admin password |
| `JWT_SECRET` | `reliquary-dev-secret-change-me` | JWT signing secret |
| `THUMBNAIL_WORKERS` | `4` | Concurrent thumbnail generation workers |
| `ARCHIVE_AFTER_DAYS` | `90` | Days before files are auto-archived |
| `ARCHIVE_CHECK_HOURS` | `24` | Hours between archival scans |

## Key Design Decisions

- **Reverse proxy**: Caddy proxies all traffic through a single origin (port 2080), eliminating CORS issues between frontend, backend, and MinIO. Presigned download URLs are rewritten to route through `/storage/*`.
- **Unix socket for backend**: The Go backend listens on a unix socket (`$DATA_DIR/backend.sock`) by default when `LISTEN_ADDR` is set to a path. Caddy proxies to it. TCP mode is also supported.
- **Multi-user with app-level auth**: Users managed via JSON file in MinIO (`admin/users.json`) with bcrypt hashing. Each user gets an isolated namespace (`{username}/files/`, `{username}/thumbs/`, etc.). No MinIO IAM — the backend is the single gatekeeper.
- **Deduplication**: SHA-256 checksum computed on upload. Per-user checksum index stored in MinIO. Duplicates return the existing key without re-uploading.
- **Metadata on objects**: Checksum, upload date, and original filename stored as MinIO user metadata (X-Amz-Meta-*). No external database needed.
- **Bounded thumbnail generation**: Worker pool with configurable concurrency (default 4). Jobs queued in a channel (buffer 100) with backpressure. Supports image resize and ffmpeg video frame extraction.
- **Ephemeral ports**: MinIO binds to random available ports to avoid conflicts. Other services discover ports by reading the port files.
- **Nix store paths in process-compose**: Commands in `minio.nix` use `pkgs.writeShellScript`, so the generated YAML references `/nix/store/...` paths directly. The YAML is only valid inside the dev shell.
- **MinIO credentials**: Default dev credentials are `minioadmin/minioadmin`. Default bucket is `reliquary`.
- **Layered dev shells**: Each shell (`infra`, `backend`, `frontend`) composes via `inputsFrom`, so every shell includes infra tooling. The default `full` shell combines backend and frontend.

## Deployment

The project builds a single all-in-one OCI container image using Nix's `dockerTools`:

```bash
# Build container (MinIO + Go backend + Caddy + ffmpeg, all from nixpkgs)
nix build .#container
docker load < result

# Build Flutter web and copy into image
cd frontend && flutter build web --release && cd ..
docker create --name tmp reliquary:latest
docker cp frontend/build/web/. tmp:/srv/web/
docker commit tmp reliquary:latest && docker rm tmp

# Or use the deploy script
./bin/deploy
```

Run with docker-compose:

```bash
cp .env.example .env    # Edit with production values
docker compose up -d    # Available at http://localhost:2080
```

### Nix Build Targets

- `nix build .#backend` — Go binary with ffmpeg in PATH
- `nix build .#container` — OCI image (reliquary.tar.gz)

### Container Architecture

Single container running three processes:
- **MinIO** (`127.0.0.1:9000`) — object storage, internal only
- **Go backend** (unix socket) — API server
- **Caddy** (`:2080`) — reverse proxy + static file server for Flutter web

MinIO data persisted via Docker volume. Flutter web build mounted at `/srv/web`.
