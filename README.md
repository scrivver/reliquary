<p align="center">
  <img src="docs/banner.png" alt="Reliquary - Digital Cold Storage" width="640">
</p>

# Reliquary

A cold storage system for forgotten artifacts.

Most data is disposable. Some should survive time.

Reliquary preserves what the world discards.

> Artifacts stored in the Reliquary are rarely important. But importance changes with time.

## What It Does

Reliquary stores personal files in a self-hosted archive with a focused file
explorer, thumbnails, duplicate detection, and storage analytics.

It is built for artifacts you want to keep, but do not need to actively work
with every day: old photos, videos, exports, documents, archives, and other
digital remnants.

## Features

- Multi-file upload with progress tracking and SHA-256 duplicate detection
- Thumbnail generation for images and videos
- File explorer with search, sorting, details, preview, download, and delete
- Storage analytics by file type and month
- Local username/password auth, OIDC auth, trusted proxy auth, or no-auth mode
- Per-user storage isolation in standalone password-auth mode
- Responsive web UI with mobile and desktop layouts
- Deployable as split containers with MinIO, RabbitMQ, API, worker, and web ingress
- Native Flutter targets for Android, iOS, Linux desktop, and web

## Getting Started

For a normal self-hosted deployment, use the Docker Compose setup:

```bash
nix develop
./bin/deploy
cp .env.example .env
docker compose up -d
```

Before exposing the service, edit `.env` and change the default secrets and
passwords.

The app is available at `http://localhost:2080` by default.

## Documentation

- [Deployment](docs/deployment.md)
- [Development](docs/development.md)
- [API Reference](docs/api-reference.md)
- [Authentication](docs/authentication.md)
- [Split-Container Deployment](docs/split-container-deployment.md)

## Platforms

Reliquary ships as a web app in the default deployment. Native Flutter builds
can also connect to a Reliquary server URL; see [Deployment](docs/deployment.md)
for build details.

## License

See the repository license.
