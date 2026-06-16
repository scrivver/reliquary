# Web Frontend Image Suggestion

## Finding

The split-container deployment currently has an image boundary mismatch.

`reliquary-ingress` contains Caddy and the Caddyfile, but it does not contain
the Flutter web build under `/srv/web`. Docker Compose fills that gap with a
host bind mount:

```yaml
ingress:
  image: reliquary-ingress:latest
  volumes:
    - ./frontend/build/web:/srv/web:ro
```

That works for local Compose because the source tree and build output are on the
host. It does not translate cleanly to Kubernetes or other image-only runtimes,
where the frontend assets need to come from an image, object store, ConfigMap, or
another explicit volume source.

For the homelab Kubernetes deployment, this forced `reliquary-infra` to create a
temporary derived image that layers `frontend/build/web` onto
`reliquary-ingress`. That is workable, but it puts application build ownership in
the infrastructure repo.

## Suggestion

Add a first-class web frontend image to the Reliquary repo and publish it from
the same container workflow as the API and worker images.

Recommended image set:

```text
reliquary-api                 Go API only
reliquary-thumbnail-worker    thumbnail worker only
reliquary-web                 Caddy plus Flutter web build
```

`reliquary-web` should contain:

- Caddy
- `docker/Caddyfile`
- built Flutter web assets copied to `/srv/web`

The existing Caddyfile can remain app-owned and keep the internal app routing:

- `/api/*` -> API service
- `/storage/*` -> MinIO service
- all other paths -> Flutter SPA fallback from `/srv/web`

This keeps Docker Compose simple and lets Kubernetes users expose a single
Reliquary web Service through their own outer ingress.

## Why This Belongs In Reliquary

The Flutter web build is application output. It should be versioned and shipped
with the matching backend release, not rebuilt by every deployment repo.

Keeping the image in Reliquary also gives every deployment target the same
artifact boundary:

```text
external proxy / ingress
  -> reliquary-web
  -> reliquary-api / minio
```

Infrastructure repos can then focus on pinning image tags, secrets, storage,
hostnames, and ingress policy.

## Implementation Outline

Add a Nix package or container derivation that builds the Flutter web app and
copies the output into the web image:

```text
nix/web-container.nix
```

The resulting image should roughly behave like:

```dockerfile
FROM caddy-runtime
COPY docker/Caddyfile /etc/caddy/Caddyfile
COPY frontend/build/web/ /srv/web/
ENTRYPOINT ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
```

If keeping the current Nix `dockerTools` style, the derivation should build or
consume the Flutter web output during the image build so CI can publish a single
self-contained image.

Update `.github/workflows/containers.yml` to publish:

```text
ghcr.io/<owner>/reliquary-web:sha-<shortsha>
ghcr.io/<owner>/reliquary-web:latest
ghcr.io/<owner>/reliquary-web:<release-tag>
```

Use the same tagging policy as `reliquary-api` and
`reliquary-thumbnail-worker`.

## Compose Impact

After adding `reliquary-web`, `docker-compose.yml` can stop bind-mounting
`frontend/build/web`:

```yaml
ingress:
  image: ghcr.io/scrivver/reliquary-web:latest
```

This makes Compose closer to the production artifact model while still keeping a
single public HTTP container for local users.

## Kubernetes Impact

Kubernetes deployments can use:

```yaml
containers:
  - name: web
    image: ghcr.io/scrivver/reliquary-web:<tag>
```

The cluster ingress only needs to route the public hostname to the `reliquary-web`
Service. End users do not need to recreate Reliquary's internal `/api`,
`/storage`, and SPA fallback routing unless they deliberately want a more
Kubernetes-native path-split deployment.

## Follow-Up Cleanup

Once `reliquary-web` exists:

- remove the homelab-only derived `reliquary-ingress-web` image build
- update `reliquary-infra` to reference `ghcr.io/scrivver/reliquary-web:<tag>`
- document that downstream deployments should pin immutable `sha-*` or release
  tags instead of `latest`
