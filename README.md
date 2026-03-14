# Reliquary

A cold storage system for forgotten artifacts.

Most data is disposable.
Some should survive time.

Reliquary preserves what the world discards.

> Artifacts stored in the Reliquary are rarely important. But importance changes with time.

## Development

### Prerequisites

- [Nix](https://nixos.org/) with flakes enabled

### Getting Started

Enter the development shell:

```bash
nix develop
```

This sets up all dependencies (Go, Flutter, MinIO, process-compose) and generates the process-compose configuration.

You can also enter a focused shell for a specific layer:

```bash
nix develop .#backend    # Go + infra tooling
nix develop .#frontend   # Flutter + infra tooling
nix develop .#infra      # Infra tooling only
```

### Infrastructure

Start the infrastructure services (MinIO):

```bash
start-infra
```

In a separate terminal (inside the dev shell), load the MinIO ports into your environment:

```bash
source load-infra-env
```

This exports `MINIO_PORT` and `MINIO_CONSOLE_PORT` for use by other services.

Stop all infrastructure services:

```bash
shutdown-infra
```

### Backend

The backend is a Go API server located in `backend/`. It provides JWT authentication, multipart file upload to MinIO, thumbnail generation, file listing, and deletion.

```bash
cd backend
source load-infra-env    # if not already done
go run .
```

The server starts on port `8080` by default (override with `PORT` env var).

#### API Endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/login` | No | Returns JWT token |
| GET | `/api/health` | No | Health check |
| POST | `/api/upload` | Yes | Multipart file upload (field: `file`) |
| GET | `/api/files` | Yes | List all archived photos |
| GET | `/api/files/presign?key=...` | Yes | Presigned download URL |
| DELETE | `/api/files?key=...` | Yes | Delete file and thumbnail |

Default credentials: `admin` / `admin` (configurable via `AUTH_USERNAME`, `AUTH_PASSWORD` env vars).

### Frontend

The frontend is a Flutter application located in `frontend/`. It targets web, Android, and iOS.

```bash
cd frontend
flutter run -d web-server    # Web (open in any browser)
flutter run -d linux         # Linux desktop
flutter run -d chrome        # Chrome (set CHROME_EXECUTABLE for Firefox)
```

Features:
- Login with JWT authentication
- Multi-file photo upload with progress tracking
- Thumbnail gallery with tap-to-view full resolution
- File deletion with confirmation
