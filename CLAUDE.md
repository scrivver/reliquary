# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Reliquary is a cold storage system for forgotten artifacts, built with Nix flakes for reproducibility. The project consists of a Go backend, a Flutter frontend, and MinIO-based infrastructure managed via process-compose.

## Development Environment

The project provides multiple dev shells via `flake.nix`:

```bash
nix develop              # Full shell (backend + frontend + infra)
nix develop .#backend    # Backend shell (Go + infra)
nix develop .#frontend   # Frontend shell (Flutter + infra)
nix develop .#infra      # Infra only (MinIO + process-compose)
```

The shell hook automatically:
- Generates `process-compose.yaml` in `.data/` from `infra/minio.nix`
- Exports `DATA_DIR`, `PC_SOCKET`, `MINIO_PORT_FILE`, `MINIO_CONSOLE_PORT_FILE`
- Adds `bin/` to PATH

## Infrastructure Commands

```bash
start-infra              # Start MinIO via process-compose (uses unix socket)
source load-infra-env    # Export MINIO_PORT and MINIO_CONSOLE_PORT (must source, not execute)
shutdown-infra           # Stop all services
```

## Architecture

- **`flake.nix`** — Dev shell definitions. Imports shell modules from `shells/` and generates the process-compose config at nix eval time using `pkgs.formats.yaml`.
- **`shells/`** — Nix shell definitions. `infra.nix` is the base shell; `backend.nix` and `frontend.nix` extend it via `inputsFrom`.
- **`backend/`** — Go backend service.
- **`frontend/`** — Flutter frontend application.
- **`infra/minio.nix`** — Defines MinIO process-compose processes as a Nix attrset. Uses ephemeral ports (allocated via Python at runtime) and writes them to `$DATA_DIR/minio/port` and `$DATA_DIR/minio/console_port`. Includes a `minio-create-bucket` process that depends on MinIO being healthy.
- **`bin/`** — Shell scripts injected into PATH by the dev shell. All require `DATA_DIR` to be set.
- **`.data/`** — Runtime directory (gitignored). Holds generated configs, MinIO data, port files, and the process-compose unix socket.

## Key Design Decisions

- **Ephemeral ports**: MinIO binds to random available ports to avoid conflicts. Other services discover ports by reading the port files.
- **Nix store paths in process-compose**: Commands in `minio.nix` use `pkgs.writeShellScript`, so the generated YAML references `/nix/store/...` paths directly. The YAML is only valid inside the dev shell.
- **Unix socket**: process-compose communicates via `$PC_SOCKET` (`$DATA_DIR/process-compose.sock`), not TCP.
- **MinIO credentials**: Default dev credentials are `minioadmin/minioadmin`. Default bucket is `smartaffiliate`.
- **Layered dev shells**: Each shell (`infra`, `backend`, `frontend`) composes via `inputsFrom`, so every shell includes infra tooling. The default `full` shell combines backend and frontend.
