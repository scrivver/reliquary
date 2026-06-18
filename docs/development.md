# Development

This guide is for working on Reliquary locally.

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- [tmux](https://github.com/tmux/tmux) for the `dev` launcher script

## Quick Start

The fastest way to start all services is:

```bash
nix develop
dev
```

This launches infrastructure, backend, and frontend in separate tmux windows.
Use `Ctrl-b` plus a window number to switch between them.

## Manual Start

Enter the development shell:

```bash
nix develop
```

This provides Go, Flutter, MinIO, RabbitMQ, Caddy, ffmpeg, process-compose, and
the scripts in `bin/`.

Focused shells are also available:

```bash
nix develop .#backend
nix develop .#frontend
nix develop .#infra
```

## Infrastructure

Start MinIO, RabbitMQ, and Caddy:

```bash
start-infra
```

In another terminal inside the dev shell, load the generated ports:

```bash
source load-infra-env
```

Stop infrastructure services:

```bash
shutdown-infra
```

The Caddy reverse proxy runs on `http://localhost:2080` and routes:

- `/api/*` to the Go backend over a Unix socket
- `/storage/*` to MinIO for presigned file downloads

## Backend

The backend lives in `backend/`. It provides authentication, file upload,
deduplication, thumbnail job publishing, storage analytics, and admin APIs.

Run it with hot reload:

```bash
start-backend
```

Or manually:

```bash
cd backend
source load-infra-env
LISTEN_ADDR=$DATA_DIR/backend.sock air
```

The server listens on a Unix socket by default for use with Caddy. For direct
TCP access, use:

```bash
PORT=8080 go run .
```

Run backend tests:

```bash
cd backend
go test ./...
```

## Frontend

The frontend lives in `frontend/` and is built with Flutter.

Run the web frontend:

```bash
start-frontend
```

Or manually:

```bash
cd frontend
flutter run -d web-server
flutter run -d linux
flutter run -d chrome
```

Run frontend checks:

```bash
cd frontend
flutter test
flutter analyze
```

## Builds

Build the backend:

```bash
nix build .#backend
```

Build the web frontend:

```bash
nix build .#frontend-web
```

Build and load container images into Docker or Podman:

```bash
nix develop
./bin/deploy
```

## User Management CLI

Admin users are intentionally not creatable through the web UI or API. Create
additional admins from the backend with the user-management command after
loading the same environment used by the API:

```bash
cd backend
RELIQUARY_USER_PASSWORD='change-me' go run ./cmd/reliquary-user create-admin --username alice
```

Create a standard user from the same command:

```bash
RELIQUARY_USER_PASSWORD='change-me' go run ./cmd/reliquary-user create-user --username bob
```

## Restoring Data From Older Releases

Lifecycle archival is no longer active. Before or immediately after upgrading an
installation that contains `archive/` objects, preview the one-time restoration:

```bash
cd backend
go run ./cmd/restore-archive
```

For a packaged container:

```bash
docker exec reliquary restore-archive
```

The command defaults to dry-run and reports destination conflicts. Resolve any
conflicts, then apply the migration:

```bash
go run ./cmd/restore-archive -apply
docker exec reliquary restore-archive -apply
```

It moves `archive/` to `files/`, moves `archive-thumbs/` to `thumbs/`, never
overwrites active objects, and rebuilds per-user checksum indexes.
