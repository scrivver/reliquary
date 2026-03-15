# Reliquary

A cold storage system for forgotten artifacts.

Most data is disposable.
Some should survive time.

Reliquary preserves what the world discards.

> Artifacts stored in the Reliquary are rarely important. But importance changes with time.

## Features

- **Multi-file upload** with progress tracking and automatic deduplication (SHA-256)
- **Thumbnail generation** for images (resize) and videos (ffmpeg first-frame extraction)
- **Multi-user support** with admin/user roles and per-user isolated storage
- **Lifecycle archival** — automatically archive files older than a configurable threshold
- **Storage analytics** — file counts, storage usage by type and month
- **Configurable server URL** — connect to different Reliquary instances (portable drive support)
- **All file types supported** — images, videos, documents, archives, etc.

## Development

### Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- [tmux](https://github.com/tmux/tmux) (optional, for the `dev` launcher script)

### Quick Start

The fastest way to start all services (requires tmux):

```bash
nix develop
dev
```

This launches infra, backend (with hot reload), and frontend in separate tmux windows. Use `Ctrl-b` + window number to switch between them.

### Manual Start

Enter the development shell:

```bash
nix develop
```

This sets up all dependencies (Go, Flutter, MinIO, Caddy, ffmpeg, process-compose) and generates the process-compose configuration.

You can also enter a focused shell for a specific layer:

```bash
nix develop .#backend    # Go + infra tooling
nix develop .#frontend   # Flutter + infra tooling
nix develop .#infra      # Infra tooling only
```

### Infrastructure

Start the infrastructure services (MinIO + Caddy reverse proxy):

```bash
start-infra
```

In a separate terminal (inside the dev shell), load the ports into your environment:

```bash
source load-infra-env
```

This exports `MINIO_PORT`, `MINIO_CONSOLE_PORT`, and `PROXY_PORT` for use by other services.

Stop all infrastructure services:

```bash
shutdown-infra
```

The Caddy reverse proxy runs on `http://localhost:2080` and routes:
- `/api/*` → Go backend (unix socket)
- `/storage/*` → MinIO (for presigned file downloads)

### Backend

The backend is a Go API server located in `backend/`. It provides JWT authentication, multi-user management, multipart file upload to MinIO, deduplication, thumbnail generation, lifecycle archival, and storage analytics.

```bash
start-backend            # loads env, runs air (hot reload) on unix socket
```

Or manually:

```bash
cd backend
source load-infra-env
LISTEN_ADDR=$DATA_DIR/backend.sock air    # or: go run .
```

The server listens on a unix socket by default for use with the Caddy proxy. For direct TCP access, use `PORT=8080 go run .` instead.

#### API Endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/login` | No | Returns JWT token with username and role |
| GET | `/api/health` | No | Health check |
| POST | `/api/upload` | Yes | Multipart file upload with dedup |
| GET | `/api/files?offset=0&limit=50` | Yes | List files (paginated) |
| GET | `/api/files/presign?key=...` | Yes | Presigned download URL |
| DELETE | `/api/files?key=...` | Yes | Delete file and thumbnail |
| GET | `/api/archive?offset=0&limit=50` | Yes | List archived files |
| POST | `/api/archive/restore?key=...` | Yes | Restore from archive |
| POST | `/api/archive/run` | Yes | Trigger archival manually |
| DELETE | `/api/archive?key=...` | Yes | Delete archived file |
| GET | `/api/stats` | Yes | Storage analytics |
| GET | `/api/admin/stats` | Admin | Aggregate analytics |
| POST | `/api/admin/users` | Admin | Create user |
| GET | `/api/admin/users` | Admin | List users |
| DELETE | `/api/admin/users/{username}` | Admin | Delete user |
| PUT | `/api/admin/users/{username}/password` | Admin* | Change password |

*Admin can change any password; users can change their own.

Default credentials: `admin` / `admin` (configurable via `AUTH_USERNAME`, `AUTH_PASSWORD` env vars).

#### Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `LISTEN_ADDR` | `:8080` | Listen address (path = unix socket) |
| `AUTH_USERNAME` | `admin` | Initial admin username |
| `AUTH_PASSWORD` | `admin` | Initial admin password |
| `THUMBNAIL_WORKERS` | `4` | Concurrent thumbnail workers |
| `ARCHIVE_AFTER_DAYS` | `90` | Days before auto-archival |
| `ARCHIVE_CHECK_HOURS` | `24` | Hours between archival scans |

### Frontend

The frontend is a Flutter application located in `frontend/`. It targets web, Android, iOS, and Linux desktop.

```bash
start-frontend           # runs flutter web server on port 3000
```

Or manually:

```bash
cd frontend
flutter run -d web-server    # Web (open in any browser)
flutter run -d linux         # Linux desktop
flutter run -d chrome        # Chrome (set CHROME_EXECUTABLE for Firefox)
```

Features:
- Login with JWT authentication (multi-user)
- Multi-file upload with progress tracking
- Thumbnail gallery with tap-to-view full resolution
- Content-type aware file icons (image, video, audio, PDF, archive)
- File metadata display (checksum, upload date, original name)
- Archive browser with restore and permanent delete
- Storage analytics dashboard
- Admin user management (create, delete, change password)
- Configurable server URL (settings screen)
- Change password (settings screen)
