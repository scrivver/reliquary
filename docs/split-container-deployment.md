# Split-Container Deployment

The default Compose deployment separates runtime responsibilities:

- `ingress`: Caddy and the Flutter web build; the only public service.
- `api`: Reliquary HTTP API and durable event/job publishers.
- `thumbnail-worker`: RabbitMQ consumer and media rendering tools.
- `minio`: persistent S3-compatible object storage.
- `rabbitmq`: persistent file-event and thumbnail queues.
- `minio-init`: one-shot bucket initialization.

This layout allows API and worker instances to be scaled independently. Do not
run `minio-init` as a replicated service.

## Build and Start

Enter the Nix development shell, then build and load all application images:

```bash
nix develop
./bin/deploy
cp .env.example .env
# Set unique MinIO, admin, and JWT secrets in .env.
docker compose up -d
```

The Flutter build is mounted read-only from `frontend/build/web`. The deployment
is available at `http://localhost:2080`.

Check startup and health:

```bash
docker compose ps
curl --fail http://localhost:2080/api/health
docker compose logs api thumbnail-worker
```

Only ingress publishes a host port. MinIO and RabbitMQ remain on the internal
Compose network. Their data is stored in `minio_data` and `rabbitmq_data`.

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
