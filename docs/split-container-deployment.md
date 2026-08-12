# Split-Container Deployment

The default Compose deployment separates runtime responsibilities:

- `ingress`: `reliquary-web`, which contains Caddy and the Flutter web build;
  the only public service.
- `api`: Reliquary HTTP API and durable event/job publishers.
- `thumbnail-worker`: RabbitMQ consumer and media rendering tools.
- `minio`: persistent S3-compatible object storage.
- `rabbitmq`: persistent file-event and thumbnail queues.
- `minio-init`: one-shot bucket initialization.

This layout allows API and worker instances to be scaled independently. Do not
run `minio-init` as a replicated service.

## Docker Compose Usage

The checked-in `docker-compose.yml` references local application image names:

- `reliquary-api:latest`
- `reliquary-thumbnail-worker:latest`
- `reliquary-web:latest`

Build and load them before starting Compose:

```bash
nix develop
./bin/deploy
cp .env.example .env
# Set unique MinIO, admin, and JWT secrets in .env.
docker compose up -d
```

`./bin/deploy` builds the three Nix container outputs and loads the resulting
tarballs into Docker or Podman. The `reliquary-web` image contains the Flutter
web build at `/srv/web`, so Compose does not need a host-side frontend bind
mount. The deployment is available at `http://localhost:2080`.

When using published images, change the Compose image names to their registry
locations, for example:

```yaml
api:
  image: ghcr.io/scrivver/reliquary-api:latest
thumbnail-worker:
  image: ghcr.io/scrivver/reliquary-thumbnail-worker:latest
  tmpfs:
    - /tmp:size=512m,mode=1777
ingress:
  image: ghcr.io/scrivver/reliquary-web:latest
```

Use SHA or version tags instead of `latest` for reproducible production
deployments.

The thumbnail worker needs a writable `/tmp` directory while generating PDF
thumbnails: it downloads the source PDF there before invoking `pdftoppm`. In
Compose, prefer a service-level tmpfs mount as shown above. A regular writable
filesystem mount also works if you want temporary files to count against node
disk instead of memory.

Check startup and health:

```bash
docker compose ps
curl --fail http://localhost:2080/api/health
docker compose logs api thumbnail-worker
```

Only the web/ingress service publishes a host port. MinIO and RabbitMQ remain on
the internal Compose network. Their data is stored in `minio_data` and
`rabbitmq_data`.

## Environment Variables

Copy `.env.example` to `.env` and edit it before starting Compose:

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d
```

Security-sensitive defaults are intentionally obvious placeholders. Change
`MINIO_ROOT_PASSWORD`, `AUTH_PASSWORD`, and `JWT_SECRET` before exposing the
deployment.

| Variable | Used by | Default | Description |
|----------|---------|---------|-------------|
| `RELIQUARY_PORT` | `ingress` | `2080` | Host port mapped to ingress port `2080`. |
| `PROXY_BASE_URL` | `api` | `http://localhost:2080` | Public base URL used when generating object URLs. |
| `MINIO_ROOT_USER` | `minio`, `minio-init`, `api`, `thumbnail-worker` | `minioadmin` | MinIO root/access key. |
| `MINIO_ROOT_PASSWORD` | `minio`, `minio-init`, `api`, `thumbnail-worker` | `change-me-in-production` | MinIO root/secret key. |
| `MINIO_BUCKET` | `minio-init`, `api`, `thumbnail-worker` | `reliquary` | Bucket created on startup and used by Reliquary. |
| `AUTH_MODE` | `api` | `full` | Authentication mode: `full`, `proxy`, `none`, or `oidc`. |
| `AUTH_PASSWORD_ENABLED` | `api` | derived from `AUTH_MODE` | Enables password login; cannot be combined with OIDC. |
| `AUTH_OIDC_ENABLED` | `api` | derived from `AUTH_MODE` | Enables OIDC bearer-token auth and OIDC login UI. |
| `AUTH_PROXY_ENABLED` | `api` | derived from `AUTH_MODE` | Enables legacy trusted-header proxy auth. |
| `AUTH_NONE_ENABLED` | `api` | derived from `AUTH_MODE` | Enables no-auth single-user mode. |
| `AUTH_USERNAME` | `api` | `admin` | Initial admin user created on first startup. |
| `AUTH_PASSWORD` | `api` | `change-me-in-production` | Initial admin password created on first startup. |
| `JWT_SECRET` | `api` | `change-me-in-production` | JWT signing secret; use a unique random value. |
| `OIDC_ISSUER_URL` | `api` | — | OIDC issuer URL. |
| `OIDC_CLIENT_ID` | `api` | — | Public OIDC client ID. |
| `OIDC_REDIRECT_URI` | `api` | `com.reliquary.app://callback` | Native app redirect URI advertised to mobile clients; register this exact URI with the OIDC provider. |
| `OIDC_USERNAME_CLAIM` | `api` | `preferred_username` | Userinfo claim used as Reliquary username. |
| `EVENTS_ENABLED` | `api` | `true` | Enables explicit file-event publishing to RabbitMQ. |
| `EVENT_QUEUE` | `api` | `engram.ingest` | RabbitMQ queue/routing key for file create/delete events. |
| `EVENT_DEVICE_NAME` | `api` | `reliquary` | Device name included in emitted file events. |
| `THUMBNAIL_QUEUE` | `api`, `thumbnail-worker` | `reliquary.thumbnail` | RabbitMQ queue/routing key for thumbnail jobs. |
| `THUMBNAIL_DEAD_QUEUE` | `thumbnail-worker` | `reliquary.thumbnail.dead` | Queue for malformed jobs or jobs that exhaust retries. |
| `THUMBNAIL_PREFETCH` | `thumbnail-worker` | `1` | Jobs prefetched per worker slot. |
| `THUMBNAIL_CONCURRENCY` | `thumbnail-worker` | `4` | Concurrent thumbnail jobs per worker container. |
| `THUMBNAIL_MAX_ATTEMPTS` | `thumbnail-worker` | `5` | Processing attempts before a job is dead-lettered. |

The Compose file sets internal-only service addresses directly:
`MINIO_ENDPOINT=minio:9000` and
`RABBITMQ_URL=amqp://guest:guest@rabbitmq:5672`. Override those only when the
API or worker connects to external infrastructure instead of the bundled
Compose services.

## Kubernetes Worker Temp Storage

When deploying the worker to Kubernetes, mount a writable `/tmp` into the worker
container. A memory-backed `emptyDir` is usually the closest equivalent to the
Compose tmpfs mount:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reliquary-thumbnail-worker
spec:
  template:
    spec:
      containers:
        - name: thumbnail-worker
          image: ghcr.io/scrivver/reliquary-thumbnail-worker:latest
          volumeMounts:
            - name: worker-tmp
              mountPath: /tmp
      volumes:
        - name: worker-tmp
          emptyDir:
            medium: Memory
            sizeLimit: 512Mi
```

If memory pressure is a concern, omit `medium: Memory` and Kubernetes will back
the `emptyDir` with node storage instead.

## Scaling

Scale stateless application processes independently:

```bash
docker compose up -d --scale api=2 --scale thumbnail-worker=3
```

Compose DNS load-balances requests from Caddy across API containers. Thumbnail
jobs are shared across worker consumers. API authentication state, checksum
indexes, and user records currently live in MinIO; concurrent mutation behavior
must be reviewed before relying on multi-API scaling for heavy write workloads.

## All-in-One Compatibility

The original combined MinIO, API, worker, and Caddy image remains available:

```bash
./bin/deploy-all-in-one
docker compose -f docker-compose.all-in-one.yml up -d
```

Use the split deployment for production-oriented operation. The all-in-one
layout remains useful for compact installations and compatibility testing.
