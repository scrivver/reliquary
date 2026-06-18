<p align="center">
  <img src="docs/banner.png" alt="Reliquary - Digital Cold Storage" width="640">
</p>

# Reliquary

A cold storage system for forgotten artifacts.

Most data is disposable.
Some should survive time.

Reliquary preserves what the world discards.

> Artifacts stored in the Reliquary are rarely important. But importance changes with time.

## Features

- **Multi-file upload** with progress tracking, duplicate detection (SHA-256), and download support
- **Thumbnail generation** for images (resize) and videos (ffmpeg first-frame extraction)
- **Multi-user support** with admin/user roles and per-user isolated storage
- **Storage analytics** — file counts, storage usage by type and month
- **Configurable server URL** — connect to different Reliquary instances (portable drive support)
- **Responsive UI** — bottom navigation on mobile, sidebar on desktop, industrial design theme
- **All file types supported** — images, videos, documents, archives, etc.
- **Cross-platform** — web, Android, iOS, Linux desktop

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

This sets up all dependencies (Go, Flutter, MinIO, RabbitMQ, Caddy, ffmpeg,
process-compose) and generates the process-compose configuration.

You can also enter a focused shell for a specific layer:

```bash
nix develop .#backend    # Go + infra tooling
nix develop .#frontend   # Flutter + infra tooling
nix develop .#infra      # Infra tooling only
```

### Infrastructure

Start the infrastructure services (MinIO, RabbitMQ, and Caddy reverse proxy):

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

The backend is a Go API server located in `backend/`. It provides JWT
authentication, multipart file upload to MinIO, explicit Engram event
publication, deduplication, thumbnail generation, and storage analytics.

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
| GET | `/api/files/presign?key=...&download=true` | Yes | Presigned download URL (`download=true` forces save) |
| DELETE | `/api/files?key=...` | Yes | Delete file and thumbnail |
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
| `AUTH_MODE` | `full` | Compatibility auth mode: `full`, `oidc`, `proxy`, or `none` |
| `AUTH_PASSWORD_ENABLED` | derived from `AUTH_MODE` | Enable username/password login; set with `AUTH_OIDC_ENABLED=true` to offer both |
| `AUTH_OIDC_ENABLED` | derived from `AUTH_MODE` | Enable OIDC bearer-token auth and frontend OIDC login |
| `AUTH_PROXY_ENABLED` | derived from `AUTH_MODE` | Enable legacy trusted-header proxy auth |
| `AUTH_NONE_ENABLED` | derived from `AUTH_MODE` | Enable no-auth single-user mode |
| `AUTH_USERNAME` | `admin` | Initial admin / default user |
| `AUTH_PASSWORD` | `admin` | Initial admin password (full mode only) |
| `OIDC_ISSUER_URL` | — | OIDC issuer URL when OIDC auth is enabled |
| `OIDC_CLIENT_ID` | — | Public OIDC client ID used by the frontend |
| `OIDC_REDIRECT_URI` | `com.reliquary.app://callback` | Native app redirect URI advertised to mobile clients; register this exact URI with the OIDC provider |
| `OIDC_USERNAME_CLAIM` | `preferred_username` | Userinfo claim used as the Reliquary username |
| `RABBITMQ_URL` | `amqp://guest:guest@127.0.0.1:5672` | Broker used for Engram file events |
| `EVENT_QUEUE` | `engram.ingest` | Predeclared RabbitMQ queue/routing key |
| `EVENT_DEVICE_NAME` | `reliquary` | Producer name in canonical file events |
| `EVENTS_ENABLED` | `true` | Set `false` only for standalone operation without Engram |
| `THUMBNAIL_QUEUE` | `reliquary.thumbnail` | Durable thumbnail job queue |
| `THUMBNAIL_DEAD_QUEUE` | `reliquary.thumbnail.dead` | Exhausted/invalid job queue |
| `THUMBNAIL_PREFETCH` | `1` | Unacked jobs reserved per worker slot |
| `THUMBNAIL_CONCURRENCY` | `4` | Concurrent jobs per worker process |
| `THUMBNAIL_MAX_ATTEMPTS` | `5` | Processing attempts before dead-lettering |

Uploads and deletes publish canonical persistent messages after the S3 mutation.
Delivery is at least once. If RabbitMQ does not confirm an event, the API returns
`503`; retry the same upload or delete to republish it.

#### Auth Modes

| Mode | Use case | Auth | User identity |
|------|----------|------|--------------|
| `full` | Standalone deployment | JWT login | From JWT token |
| `oidc` | Mind Palace / external identity provider | OIDC access token | From configured OIDC userinfo claim |
| `proxy` | Legacy/advanced trusted proxy deployment | None in Reliquary | From `X-Reliquary-User` header |
| `none` | Single-user, CLI scripts, embedded | None | Fixed default user |

The frontend discovers enabled login methods from `GET /api/auth/config`.
`AUTH_MODE` keeps existing deployments working, while the provider flags allow
combined modes. For example, set `AUTH_PASSWORD_ENABLED=true` and
`AUTH_OIDC_ENABLED=true` to show both username/password and OIDC login.

**Proxy mode** is legacy/advanced. Reliquary must only be reachable through the
trusted proxy, and the proxy must strip inbound `X-Reliquary-User` before
setting its own value. Example with nginx:
```nginx
location / {
    proxy_set_header X-Reliquary-User $remote_user;
    proxy_pass http://127.0.0.1:2080;
}
```

**None mode** — no login required, all files belong to the default user:
```bash
AUTH_MODE=none MINIO_PORT=9000 go run .
```

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
- Login with JWT authentication (multi-user) and server URL configuration
- Multi-file upload with progress tracking and duplicate detection
- Thumbnail gallery with tap-to-view full resolution
- File download, details, and delete via long-press menu
- Content-type aware file icons (image, video, audio, PDF, archive)
- File metadata display (checksum, upload date, original name)
- Storage analytics dashboard
- Admin user management (create, delete, change password)
- Configurable server URL (login screen + settings)
- Responsive layout: bottom navigation (mobile), sidebar (desktop)
- Change password (settings screen)

## Deployment

### Docker Compose Usage

The default `docker-compose.yml` starts separate `ingress`, `api`,
`thumbnail-worker`, `minio`, `minio-init`, and `rabbitmq` services. It expects
the Reliquary images to exist locally unless you change the image names to a
registry path such as `ghcr.io/scrivver/reliquary-api:latest` or
`ghcr.io/scrivver/reliquary-web:latest`.

For local testing, build and load the images first:

```bash
nix develop
./bin/deploy

cp .env.example .env
# Edit passwords and JWT_SECRET before production use.
docker compose up -d
```

The application is available at `http://localhost:2080`. With the checked-in
Compose defaults, the initial Reliquary login is `admin` /
`change-me-in-production`; change it in `.env` before real use.

### Build from Source

Requires [Nix](https://nixos.org/) with flakes enabled and [Docker](https://docs.docker.com/get-docker/) or [Podman](https://podman.io/).

```bash
# Build and load the API, worker, and web images
nix develop
./bin/deploy
```

Or use the deploy script which does all of the above (auto-detects docker/podman):

```bash
./bin/deploy
```

### Run

```bash
# Copy and edit the environment file
cp .env.example .env
# Edit .env with your production values (especially JWT_SECRET and passwords)

# Start (docker or podman)
docker compose up -d
# or: podman compose up -d
```

The application is available at `http://localhost:2080`.

### Configuration

Container configuration is provided through `.env` and consumed by
`docker-compose.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `RELIQUARY_PORT` | `2080` | Host port mapped to ingress port `2080` |
| `PROXY_BASE_URL` | `http://localhost:2080` | Public URL used when generating storage links |
| `MINIO_ROOT_USER` | `minioadmin` | MinIO root username |
| `MINIO_ROOT_PASSWORD` | `change-me-in-production` | MinIO root password |
| `MINIO_BUCKET` | `reliquary` | MinIO bucket name |
| `AUTH_MODE` | `full` | Authentication mode: `full`, `proxy`, `none`, or `oidc` |
| `AUTH_PASSWORD_ENABLED` | derived from `AUTH_MODE` | Enables password login; can be combined with OIDC |
| `AUTH_OIDC_ENABLED` | derived from `AUTH_MODE` | Enables OIDC bearer-token auth and OIDC login UI |
| `AUTH_PROXY_ENABLED` | derived from `AUTH_MODE` | Enables legacy trusted-header proxy auth |
| `AUTH_NONE_ENABLED` | derived from `AUTH_MODE` | Enables no-auth single-user mode |
| `AUTH_USERNAME` | `admin` | Initial admin username seeded on first startup |
| `AUTH_PASSWORD` | `change-me-in-production` | Initial admin password seeded on first startup |
| `JWT_SECRET` | `change-me-in-production` | JWT signing secret; must be unique in production |
| `OIDC_ISSUER_URL` | — | OIDC issuer URL |
| `OIDC_CLIENT_ID` | — | Public OIDC client ID |
| `OIDC_REDIRECT_URI` | `com.reliquary.app://callback` | Native app redirect URI advertised to mobile clients; register this exact URI with the OIDC provider |
| `OIDC_USERNAME_CLAIM` | `preferred_username` | Userinfo claim used as Reliquary username |
| `EVENTS_ENABLED` | `true` | Publish explicit file events for downstream consumers |
| `EVENT_QUEUE` | `engram.ingest` | RabbitMQ queue/routing key for file events |
| `EVENT_DEVICE_NAME` | `reliquary` | Device name written into emitted file events |
| `THUMBNAIL_QUEUE` | `reliquary.thumbnail` | RabbitMQ queue/routing key for thumbnail jobs |
| `THUMBNAIL_DEAD_QUEUE` | `reliquary.thumbnail.dead` | Queue for malformed or exhausted thumbnail jobs |
| `THUMBNAIL_PREFETCH` | `1` | Jobs prefetched per worker slot |
| `THUMBNAIL_CONCURRENCY` | `4` | Concurrent thumbnail jobs per worker container |
| `THUMBNAIL_MAX_ATTEMPTS` | `5` | Attempts before dead-lettering |

### Restoring Data From Older Releases

Lifecycle archival is no longer active. Before or immediately after upgrading an
installation that contains `archive/` objects, preview the one-time restoration:

```bash
# Development, with infrastructure running and environment loaded
cd backend
go run ./cmd/restore-archive

# Packaged container
docker exec reliquary restore-archive
```

The command defaults to dry-run and reports destination conflicts. Resolve any
conflicts, then apply the migration:

```bash
go run ./cmd/restore-archive -apply
# or
docker exec reliquary restore-archive -apply
```

It moves `archive/` to `files/`, moves `archive-thumbs/` to `thumbs/`, never
overwrites active objects, and rebuilds per-user checksum indexes.

### Architecture

The default Compose deployment runs separate web, API, thumbnail worker, MinIO,
and RabbitMQ containers. Only the web container publishes port `2080`; storage
and queue traffic stays on the internal network. See
[`docs/split-container-deployment.md`](docs/split-container-deployment.md) for
build, scaling, health-check, and all-in-one compatibility instructions.

### Mobile Apps

Build native apps that connect to your Reliquary instance:

```bash
cd frontend

# Android
flutter build apk --release

# iOS (requires macOS + Xcode)
flutter build ipa --release
```

Set the server URL on the login screen to point to your deployment (e.g., `http://192.168.1.100:2080`).

GitHub Actions also builds the Android release APK on frontend changes. Pull
requests and branch pushes publish it as a workflow artifact; `v*` tags also
attach the APK to the matching GitHub Release. The current Android release build
uses the debug signing config, so treat it as an installable test artifact until
production signing keys are configured.

### Manual Setup (without Nix or containers)

If you prefer to set up each component manually:

#### Prerequisites

- [Go](https://go.dev/) 1.22+
- [Flutter](https://flutter.dev/) 3.x
- [MinIO](https://min.io/) server and client (`mc`)
- [RabbitMQ](https://www.rabbitmq.com/) 4.x
- [Caddy](https://caddyserver.com/) 2.x
- [ffmpeg](https://ffmpeg.org/) (optional, for video thumbnails)

#### 1. Start MinIO

```bash
# Start MinIO (adjust paths as needed)
mkdir -p /var/data/minio
MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin \
  minio server /var/data/minio --address "127.0.0.1:9000"

# Create the bucket
mc alias set local http://127.0.0.1:9000 minioadmin minioadmin --api S3v4
mc mb --ignore-existing local/reliquary
mc anonymous set download local/reliquary
```

#### 2. Start RabbitMQ

Start RabbitMQ and declare a durable `engram.ingest` queue bound to
`amq.direct` with routing key `engram.ingest`. Queue topology is an
infrastructure responsibility; the backend validates it but does not create it.

#### 3. Build and run the Go backend

```bash
cd backend
go build -o reliquary-be .

MINIO_PORT=9000 \
RABBITMQ_URL=amqp://guest:guest@127.0.0.1:5672 \
LISTEN_ADDR=/tmp/reliquary-backend.sock \
JWT_SECRET=your-secret-here \
AUTH_USERNAME=admin \
AUTH_PASSWORD=your-password \
  ./reliquary-be
```

#### 4. Build Flutter web

```bash
cd frontend
flutter build web --release
```

#### 5. Configure and run Caddy

Create a `Caddyfile`:

```caddyfile
:2080 {
  handle /api/* {
    reverse_proxy unix//tmp/reliquary-backend.sock
  }

  handle /storage/* {
    uri strip_prefix /storage
    reverse_proxy 127.0.0.1:9000 {
      header_up Host 127.0.0.1:9000
      header_down -Access-Control-Allow-Origin
      header_down -Access-Control-Allow-Methods
      header_down -Access-Control-Allow-Headers
    }
  }

  handle {
    root * frontend/build/web
    file_server
    try_files {path} /index.html
  }
}
```

```bash
caddy run --config Caddyfile
```

The application is available at `http://localhost:2080`.

#### Environment Variables

See the [Configuration](#configuration) section above for all available options.
