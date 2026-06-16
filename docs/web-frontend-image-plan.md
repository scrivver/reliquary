# Web Frontend Image Plan

Status: implemented.

## Goal

Ship the Flutter web frontend as a first-class Reliquary container image instead
of requiring deployment repos or Compose hosts to provide `frontend/build/web`.
The production split should publish these application images:

- `reliquary-api`: Go API only.
- `reliquary-thumbnail-worker`: thumbnail consumer and media tools.
- `reliquary-web`: Caddy, `docker/Caddyfile`, and built Flutter web assets.
- `reliquary`: retained all-in-one compatibility image.

## Current Problem

`reliquary-ingress` contains Caddy and routing config but not the frontend
assets. `docker-compose.yml` compensates with:

```yaml
volumes:
  - ./frontend/build/web:/srv/web:ro
```

That is acceptable for local source-tree testing, but it is the wrong artifact
boundary for GHCR and Kubernetes. The app repo should own the matching frontend
build for each release.

## Phase 1: Build Frontend as a Nix Output

Added `frontend-web`, which produces only static web assets:

```text
nix/frontend-web.nix -> $out/share/reliquary/web
```

The derivation runs the equivalent of:

```bash
cd frontend
flutter pub get
flutter build web --release
```

and exposes the Flutter web build as the package output. The output remains
independent from Caddy so tests and future image layouts can reuse it.

## Phase 2: Replace Ingress Image With Web Image

Added `nix/web-container.nix` with:

- Caddy.
- CA certificates and `curl`.
- `reliquary-web-healthcheck`.
- `docker/Caddyfile` at `/etc/caddy/Caddyfile`.
- `frontend-web` output copied to `/srv/web`.

It is exported from `flake.nix` as `packages.web-container`. The image name is
`reliquary-web:latest`. The existing `reliquary-ingress` output remains for
compatibility, but new docs and Compose use `reliquary-web`.

## Phase 3: Update Local Compose and Deploy Scripts

Changed `docker-compose.yml`:

```yaml
ingress:
  image: reliquary-web:latest
  # remove ./frontend/build/web bind mount
```

Updated `bin/deploy` to build/load:

```text
api-container
thumbnail-worker-container
web-container
```

Local Compose no longer depends on a host-side Flutter build at runtime. It only
needs the locally loaded image.

## Phase 4: Publish From GitHub Actions

Updated `.github/workflows/containers.yml` to publish:

```text
ghcr.io/scrivver/reliquary-web:latest
ghcr.io/scrivver/reliquary-web:sha-<shortsha>
ghcr.io/scrivver/reliquary-web:<release-tag>
```

Keep PR behavior as build-only. Keep `latest` only for the default branch and
prefer `sha-*` or release tags in production deployments.

## Phase 5: Documentation and Migration

Updated deployment docs to make `reliquary-web` the public HTTP container. Note
that Kubernetes should route the external hostname to the `reliquary-web`
Service, while `reliquary-api`, MinIO, and RabbitMQ remain internal.

For one transition period, document that older Compose users may still have
`reliquary-ingress` plus the `frontend/build/web` bind mount. After downstream
deployments move to `reliquary-web`, remove the old ingress image or leave it as
a development-only artifact.

## Verification

Before considering the phase done:

1. `nix build .#frontend-web` produces `index.html` and Flutter assets.
2. `nix build .#web-container` succeeds.
3. `docker load` the image and run `docker compose up -d` without a frontend
   bind mount.
4. `curl --fail http://localhost:2080/index.html` succeeds.
5. `curl --fail http://localhost:2080/api/health` succeeds through Caddy.
6. Upload a file and confirm `/storage/*` and thumbnail display still work.
7. GHCR workflow publishes `reliquary-web` with the same tag policy as API and
   worker images.
