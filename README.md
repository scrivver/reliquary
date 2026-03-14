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

This sets up all dependencies and generates the process-compose configuration.

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
