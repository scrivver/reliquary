# Deployment

The default deployment uses Docker Compose with separate services for ingress,
API, thumbnail worker, MinIO, and RabbitMQ.

The thumbnail worker requires a writable `/tmp` directory for PDF thumbnail
generation because it downloads each source PDF before calling `pdftoppm`. The
checked-in Compose files mount `/tmp` as tmpfs for the worker. Kubernetes
deployments should mount `/tmp` with either a memory-backed `emptyDir` or a
regular writable filesystem-backed `emptyDir`.

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
| `AUTH_MODE` | `full` | Base authentication mode: `full`, `proxy`, `none`, or `oidc`. Provider flags override what it implies. |
| `AUTH_PASSWORD_ENABLED` | derived from `AUTH_MODE` | Enables password login; cannot be combined with OIDC |
| `AUTH_OIDC_ENABLED` | derived from `AUTH_MODE` | Enables OIDC bearer-token auth and OIDC login UI |
| `AUTH_PROXY_ENABLED` | derived from `AUTH_MODE` | Enables legacy trusted-header proxy auth |
| `AUTH_PROXY_SHARED_SECRET` | - | Secret the upstream proxy must send as `X-Reliquary-Proxy-Secret`; required in proxy mode |
| `AUTH_PROXY_INSECURE_TRUST_HEADER` | `false` | Opt out of the shared secret requirement; only safe when the API is reachable solely from the proxy |
| `AUTH_NONE_ENABLED` | derived from `AUTH_MODE` | Enables no-auth single-user mode |
| `TRUSTED_PROXIES` | loopback + RFC1918 + ULA | Comma-separated CIDRs or addresses whose `X-Forwarded-For` is believed; see [Client Addresses](#client-addresses) |
| `AUTH_USERNAME` | `admin` | Initial admin username seeded on first startup |
| `AUTH_PASSWORD` | `change-me-in-production` | Initial admin password seeded on first startup |
| `JWT_SECRET` | `change-me-in-production` | JWT signing secret; must be unique in production |
| `OIDC_ISSUER_URL` | - | OIDC issuer URL; must match the `iss` claim exactly |
| `OIDC_CLIENT_ID` | - | Public OIDC client ID; also the default expected audience |
| `OIDC_AUDIENCE` | `OIDC_CLIENT_ID` | `aud` claim an access token must carry; see [IdP Configuration](idp-configuration.md) |
| `OIDC_ALLOW_OPAQUE_TOKENS` | `false` | Accept non-JWT access tokens, which cannot be audience-checked |
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

## Object Storage And Bandwidth

Reliquary serves every file byte through its own infrastructure. Clients never
talk to object storage directly: downloads are authorized at the edge by
`forward_auth` and then streamed object storage → ingress → client. This keeps
a single origin, avoids any CORS policy on the bucket, and means a leaked
presigned URL is useless to anyone who cannot also pass the auth check.

The cost of that design is bandwidth, and it decides where you can host.

### Which Components Carry File Bytes

| Component | Traffic | Proportional to |
|---|---|---|
| Ingress | Downloads, outbound to clients | Download volume |
| API | Uploads, outbound to object storage | Upload volume |
| API | Batch zip downloads | Zip download volume |
| Thumbnail worker | Reads originals, writes thumbnails | Upload volume |

Downloads are the dominant cost for most deployments, and they are carried by
the ingress. In the bundled Compose file every component runs on one host, so
that host carries all of it.

### Local MinIO

With MinIO co-located with the ingress, object storage → ingress is loopback or
a container network. Only the client-facing hop crosses the WAN, so egress is
counted once and there is nothing to plan around.

### Remote Object Storage (R2, S3)

With a remote bucket, every downloaded byte crosses the WAN twice: inbound from
the provider to the ingress, then outbound to the client. Cloudflare R2 charges
no egress, but that saving is consumed by your own node — you pay your host's
egress for 100% of download traffic regardless.

**Run the ingress on a host with high egress.** A VPS with generous or
unmetered transfer is the intended topology.

Do not put the ingress on a home connection when using remote storage. Every
byte crosses the link twice, and downloads are capped by your **upstream**
rather than by the provider: on a 500/50 Mbps line, every download runs at
roughly 50 Mbps no matter how fast R2 is. You would get the durability and
capacity of remote storage and none of its delivery benefit.

Components can be split. Only the ingress needs high egress for downloads; the
API and thumbnail worker carry traffic proportional to uploads, which is
usually far smaller.

### Configuring R2

R2 is S3-compatible and needs no code changes:

```env
MINIO_ENDPOINT=<ACCOUNT_ID>.r2.cloudflarestorage.com
MINIO_USE_SSL=true
MINIO_ACCESS_KEY=<R2 API token access key>
MINIO_SECRET_KEY=<R2 API token secret>
MINIO_BUCKET=reliquary
```

Remove the `minio` and `minio-init` services from `docker-compose.yml` and
create the bucket in the R2 dashboard instead.

R2 defines its bucket region as `auto` and treats an empty region as an alias
for it, so no region setting is required.

The ingress must send the bucket hostname as `Host`. SigV4 binds the hostname
into the signature, so forwarding the client's `Host` produces
`SignatureDoesNotMatch`:

```caddyfile
reverse_proxy https://<ACCOUNT_ID>.r2.cloudflarestorage.com {
  header_up Host <ACCOUNT_ID>.r2.cloudflarestorage.com
  header_up -Authorization
  header_down -Access-Control-Allow-Origin
  header_down -Access-Control-Allow-Methods
  header_down -Access-Control-Allow-Headers
}
```

`header_up -Authorization` is required. The client sends a Bearer token for the
`forward_auth` check, but the object is authenticated by the presigned query
signature, and object storage rejects a request carrying both with `request has
multiple authentication types`.

No CORS policy is needed on the bucket, because the browser only ever talks to
the Reliquary origin. This also avoids a documented R2 behaviour: expired
presigned URLs are returned without CORS headers, so browser scripts cannot
read the error. Serving through the ingress sidesteps that entirely.

Note that `ListObjects` is a Class A operation on R2 and is billed at a higher
rate than reads. See `file-index-manifest-plan.md` for the plan to stop calling
it on normal file listings.

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

## Desktop Apps

Build desktop apps locally:

```bash
cd frontend
flutter build linux --release
flutter build windows --release
```

GitHub Actions builds Linux and Windows desktop release bundles on frontend
changes. Pull requests, branch pushes, tags, and manual dispatches publish the
bundles as workflow artifacts named `reliquary-linux-x64` and
`reliquary-windows-x64`.

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
```

The bucket must **not** have an anonymous download policy. Access to objects is
guarded at the proxy edge: Caddy runs an authenticated `forward_auth` check
against the backend before proxying `/storage/*` to MinIO. Presigned URLs still
provide per-request S3 signatures, but the edge check additionally requires a
valid reliquary session/JWT that owns the object's key.

### Proxy Auth Mode

With `AUTH_MODE=proxy` the backend takes the caller's identity from the
`X-Reliquary-User` header set by an upstream authenticating proxy
(Authelia, oauth2-proxy, Cloudflare Access, and similar). That header is only
meaningful if it provably came from that proxy, so the upstream must also send
`AUTH_PROXY_SHARED_SECRET` as `X-Reliquary-Proxy-Secret`. Requests with a
missing or mismatched secret, or with a missing or malformed username, are
rejected with `401` — there is no fallback to `AUTH_USERNAME`.

The backend refuses to start in proxy mode without a shared secret. If the API
is genuinely unreachable except from the proxy (a unix socket, or an isolated
container network), set `AUTH_PROXY_INSECURE_TRUST_HEADER=true` to accept the
identity header unverified. In that configuration also strip inbound
`X-Reliquary-User` at every hop in front of the backend, since anyone who can
reach it directly can then impersonate any user.

The same check guards `/storage/*`: the edge `forward_auth` call to
`/api/auth/check` runs under this middleware, so an unverified request never
reaches MinIO.

Note that proxy auth only takes effect when password and OIDC auth are both
disabled. If either is enabled, `X-Reliquary-User` is ignored and the backend
logs a warning at startup.

### Client Addresses

Failed logins and self-service password changes are rate limited per client
address. Behind a reverse proxy every request arrives from the proxy, so the
real client is read from `X-Forwarded-For` — but that header is written by
whoever sent the request, so it is believed only from a peer listed in
`TRUSTED_PROXIES`. From anywhere else the connection address is used and the
header ignored, otherwise a caller could rotate it and draw a fresh quota per
attempt.

The default covers the topologies Reliquary ships: loopback, RFC1918, and IPv6
ULA. In the bundled Compose file the API publishes no ports and is reachable
only from the `web` container, so the default is already correct. Setting
`TRUSTED_PROXIES=` explicitly empty trusts no peer at all — appropriate if the
API is exposed directly, though it also means every client behind a proxy
shares one quota.

Proxies append to the header, so the chain is read right to left and the first
entry that is not itself a trusted proxy is taken as the client.

If you put another proxy in front of Caddy (a CDN, or nginx terminating TLS),
configure **both** sides:

```caddyfile
# Caddy: without this it discards the inbound chain and reports its own peer
servers {
  trusted_proxies static 203.0.113.0/24
}
```

```env
# Reliquary: add the same upstream so its hop is skipped when reading the chain
TRUSTED_PROXIES=127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7,203.0.113.0/24
```

Configuring only Caddy re-opens the bypass: Caddy would begin forwarding the
client's unverified chain, and Reliquary would have no way to tell which hops
to believe.

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

> **The `/storage/*` block is a security control, not routing.** Object
> ownership is enforced by the `forward_auth` call below: it is the only thing
> stopping one user downloading another's files. A proxy that routes
> `/storage/*` to object storage *without* it fails open — every presigned URL
> becomes readable by anyone holding the link, with no error to notice.
>
> Prefer fronting the bundled ingress instead of reproducing this. The
> `reliquary-web` image already contains a maintained copy of this config, so
> an external proxy (nginx, Traefik, a CDN) only needs to forward everything to
> its port. Reimplement the block below only if you are running without
> containers, and treat it as security-sensitive when you do.

Create a `Caddyfile`:

```caddyfile
:2080 {
  handle /api/* {
    reverse_proxy unix//tmp/reliquary-backend.sock
  }

  handle /storage/* {
    forward_auth unix//tmp/reliquary-backend.sock {
      uri /api/auth/check
    }

    uri strip_prefix /storage
    reverse_proxy 127.0.0.1:9000 {
      header_up Host 127.0.0.1:9000
      # Required. The client sends a Bearer token for the check above, but the
      # object is authenticated by the presigned query signature, and object
      # storage rejects a request carrying both with "request has multiple
      # authentication types".
      header_up -Authorization
      header_down -Access-Control-Allow-Origin
      header_down -Access-Control-Allow-Methods
      header_down -Access-Control-Allow-Headers
    }
  }

  handle {
    root * frontend/build/web

    # Flutter does not content-hash these, so without this the browser applies
    # heuristic caching and keeps serving the previous bundle after an upgrade.
    @bundle path / /index.html /flutter_bootstrap.js /flutter_service_worker.js /main.dart.js /version.json
    header @bundle Cache-Control "no-cache"

    file_server
    try_files {path} /index.html
  }
}
```

Run Caddy:

```bash
caddy run --config Caddyfile
```
