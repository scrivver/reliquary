# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Reliquary is a cold storage system for forgotten artifacts, built with Nix flakes for reproducibility. The project consists of a Go backend, a Flutter frontend, and MinIO-based infrastructure managed via process-compose.

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
start-infra              # Start MinIO + Caddy proxy via process-compose (uses unix socket)
source load-infra-env    # Export MINIO_PORT, MINIO_CONSOLE_PORT, PROXY_PORT (must source, not execute)
shutdown-infra           # Stop all services
```

## Architecture

- **`flake.nix`** — Dev shell definitions. Imports shell modules from `shells/` and generates the process-compose config at nix eval time using `pkgs.formats.yaml`.
- **`shells/`** — Nix shell definitions. `infra.nix` is the base shell; `backend.nix` and `frontend.nix` extend it via `inputsFrom`.
- **`backend/`** — Go API server (chi router, JWT auth, multipart upload, thumbnail generation).
  - `config/` — Environment-based configuration (MinIO endpoint, auth credentials, JWT secret).
  - `auth/` — JWT login handler and auth middleware.
  - `handler/` — HTTP handlers for upload, file listing, presigned download, and deletion.
  - `storage/` — MinIO client wrapper (put, get, list, delete, presign, stat).
  - `worker/` — Thumbnail generation (300px width, JPEG quality 80, uses `x/image`).
- **`frontend/`** — Flutter application (web, Android, iOS, Linux desktop targets).
  - `lib/config.dart` — API base URL configuration (points to Caddy proxy).
  - `lib/models/` — Data models (FileItem).
  - `lib/services/` — Auth service (JWT + shared_preferences) and API service (Dio + multipart upload).
  - `lib/screens/` — Login, gallery (thumbnail grid + full-res viewer), and upload (multi-file with progress).
- **`infra/minio.nix`** — Defines MinIO process-compose processes as a Nix attrset. Uses ephemeral ports (allocated via Python at runtime) and writes them to `$DATA_DIR/minio/port` and `$DATA_DIR/minio/console_port`. Includes a `minio-create-bucket` process that depends on MinIO being healthy.
- **`infra/caddy.nix`** — Caddy reverse proxy process. Routes `/api/*` to the Go backend (unix socket) and `/storage/*` to MinIO. Handles CORS and strips duplicate MinIO CORS headers. Listens on port 2080 by default.
- **`bin/`** — Shell scripts injected into PATH by the dev shell. All require `DATA_DIR` to be set.
- **`.data/`** — Runtime directory (gitignored). Holds generated configs, MinIO data, Caddy config, port files, and the process-compose unix socket.

## Backend API

All endpoints except `/api/login` and `/api/health` require a `Bearer` JWT token in the `Authorization` header.

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/login` | Authenticate with username/password, returns JWT |
| GET | `/api/health` | Health check |
| POST | `/api/upload` | Multipart file upload (field: `file`), stores in MinIO and triggers thumbnail generation |
| GET | `/api/files` | List all photos with thumbnail keys |
| GET | `/api/files/presign?key=...` | Get presigned download URL for a file or thumbnail |
| DELETE | `/api/files?key=...` | Delete a file and its thumbnail |

## Running Locally

```bash
# 1. Start infra (MinIO + Caddy) and load ports
start-infra
source load-infra-env

# 2. Run backend on unix socket (in backend/)
LISTEN_ADDR=$DATA_DIR/backend.sock go run .

# 3. Run frontend (in frontend/)
flutter run -d web-server    # or: flutter run -d linux
```

All traffic goes through the Caddy proxy at `http://localhost:2080`:
- `/api/*` → Go backend (unix socket at `$DATA_DIR/backend.sock`)
- `/storage/*` → MinIO (presigned download URLs are rewritten to this path)

Default auth credentials: `admin` / `admin` (configurable via `AUTH_USERNAME` and `AUTH_PASSWORD` env vars).

## Key Design Decisions

- **Reverse proxy**: Caddy proxies all traffic through a single origin (port 2080), eliminating CORS issues between frontend, backend, and MinIO. Presigned download URLs are rewritten to route through `/storage/*`.
- **Unix socket for backend**: The Go backend listens on a unix socket (`$DATA_DIR/backend.sock`) by default when `LISTEN_ADDR` is set to a path. Caddy proxies to it. TCP mode is also supported.
- **Ephemeral ports**: MinIO binds to random available ports to avoid conflicts. Other services discover ports by reading the port files.
- **Nix store paths in process-compose**: Commands in `minio.nix` use `pkgs.writeShellScript`, so the generated YAML references `/nix/store/...` paths directly. The YAML is only valid inside the dev shell.
- **Unix socket**: process-compose communicates via `$PC_SOCKET` (`$DATA_DIR/process-compose.sock`), not TCP.
- **MinIO credentials**: Default dev credentials are `minioadmin/minioadmin`. Default bucket is `smartaffiliate`.
- **Layered dev shells**: Each shell (`infra`, `backend`, `frontend`) composes via `inputsFrom`, so every shell includes infra tooling. The default `full` shell combines backend and frontend.
