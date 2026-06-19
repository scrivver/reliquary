# Deployment

The default deployment uses Docker Compose with separate services for ingress,
API, thumbnail worker, MinIO, and RabbitMQ.

## Docker Compose

Build and load the images locally:

```bash
nix develop
./bin/deploy
```

Create and edit the environment file:

```bash
cp .env.example .env
$EDITOR .env
```

Change production secrets before exposing the service:

- `MINIO_ROOT_PASSWORD`
- `AUTH_PASSWORD`
- `JWT_SECRET`

Start the stack:

```bash
docker compose up -d
```

Or with Podman:

```bash
podman compose up -d
```

The application is available at `http://localhost:2080` by default.

See [Split-Container Deployment](split-container-deployment.md) for scaling,
health checks, published-image usage, and all-in-one compatibility.

## Configuration

Container configuration is provided through `.env` and consumed by
`docker-compose.yml`.

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
| `OIDC_ISSUER_URL` | - | OIDC issuer URL |
| `OIDC_CLIENT_ID` | - | Public OIDC client ID |
| `OIDC_REDIRECT_URI` | `com.reliquary.app://callback` | Native app redirect URI advertised to mobile clients |
| `OIDC_USERNAME_CLAIM` | `preferred_username` | Userinfo claim used as Reliquary username |
| `EVENTS_ENABLED` | `true` | Publish explicit file events for downstream consumers |
| `EVENT_QUEUE` | `engram.ingest` | RabbitMQ queue/routing key for file events |
| `EVENT_DEVICE_NAME` | `reliquary` | Device name written into emitted file events |
| `THUMBNAIL_QUEUE` | `reliquary.thumbnail` | RabbitMQ queue/routing key for thumbnail jobs |
| `THUMBNAIL_DEAD_QUEUE` | `reliquary.thumbnail.dead` | Queue for malformed or exhausted thumbnail jobs |
| `THUMBNAIL_PREFETCH` | `1` | Jobs prefetched per worker slot |
| `THUMBNAIL_CONCURRENCY` | `4` | Concurrent thumbnail jobs per worker container |
| `THUMBNAIL_MAX_ATTEMPTS` | `5` | Attempts before dead-lettering |

## Mobile Apps

Build native apps that connect to your Reliquary instance:

```bash
cd frontend
flutter build apk --release
flutter build ipa --release
```

Set the server URL on the login screen to point to your deployment, for example
`http://192.168.1.100:2080`.

GitHub Actions builds the Android release APK on frontend changes. Pull
requests and branch pushes publish it as a workflow artifact. `v*` tags also
attach the APK to the matching GitHub Release. The current Android release build
uses the debug signing config, so treat it as an installable test artifact until
production signing keys are configured.

## File Index Maintenance

Reliquary stores per-user file manifests at:

```text
indexes/{username}/files.json
```

The API uses these manifests for file listing and stats so normal browsing does
not call object-storage `ListObjects`.

For existing data, imported files, or manifest repair, run:

```bash
cd backend
go run ./cmd/rebuild-file-index --username alice
go run ./cmd/rebuild-file-index --all
```

In the Compose deployment, run the installed command from the API service:

```bash
docker compose exec api rebuild-file-index --all
```

If a manifest is missing, `/api/files` repairs it once by rebuilding from object
storage. Run the rebuild command explicitly after large imports or migrations so
the first user request does not pay that cost.

## Manual Setup Without Nix Or Containers

Install:

- [Go](https://go.dev/) 1.22+
- [Flutter](https://flutter.dev/) 3.x
- [MinIO](https://min.io/) server and client (`mc`)
- [RabbitMQ](https://www.rabbitmq.com/) 4.x
- [Caddy](https://caddyserver.com/) 2.x
- [ffmpeg](https://ffmpeg.org/) for video thumbnails

### Start MinIO

```bash
mkdir -p /var/data/minio
MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin \
  minio server /var/data/minio --address "127.0.0.1:9000"

mc alias set local http://127.0.0.1:9000 minioadmin minioadmin --api S3v4
mc mb --ignore-existing local/reliquary
mc anonymous set download local/reliquary
```

### Start RabbitMQ

Start RabbitMQ and declare a durable `engram.ingest` queue bound to
`amq.direct` with routing key `engram.ingest`. Queue topology is an
infrastructure responsibility; the backend validates it but does not create it.

### Build And Run The Backend

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

### Build Flutter Web

```bash
cd frontend
flutter build web --release
```

### Configure And Run Caddy

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

Run Caddy:

```bash
caddy run --config Caddyfile
```
