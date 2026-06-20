# Repository Guidelines

## Project Structure & Module Organization

Reliquary is split into a Go backend, Flutter frontend, Nix build definitions, and infrastructure helpers.

- `backend/` contains the Go API, thumbnail worker, storage, auth, events, and command binaries under `backend/cmd/`.
- `frontend/` contains the Flutter app: code in `frontend/lib/`, tests in `frontend/test/`, web assets in `frontend/web/`, and fonts in `frontend/assets/`.
- `infra/`, `shells/`, and `nix/` define MinIO/RabbitMQ/Caddy services, dev shells, and build/container packages.
- `bin/` holds developer entry points such as `dev`, `start-infra`, `start-backend`, and `start-frontend`.
- `docs/` stores design notes and plans. Runtime data is generated under `.data/` and should not be committed.

## Build, Test, and Development Commands

- `nix develop` enters a shell with Go, Flutter, infra tools, and `bin/` on `PATH`.
- `dev` starts infra, backend, worker, and frontend in one process-compose session.
- `start-infra` launches MinIO, RabbitMQ, and Caddy; follow with `source load-infra-env`.
- `start-backend` runs the Go backend with hot reload in the current terminal.
- `start-frontend` runs the Flutter web server on port 3000 in the current terminal.
- `cd backend && go test ./...` runs backend unit tests.
- `cd frontend && flutter test` runs Flutter tests; `flutter analyze` runs Dart lints.
- `nix build .#backend` builds backend binaries; `nix build .#frontend-web` builds the web app.

## Coding Style & Naming Conventions

Use `gofmt` for Go and `dart format` for Dart. Go packages use short lowercase names such as `auth`, `handler`, and `storage`; tests follow `*_test.go`. Dart files use `snake_case.dart`, classes use `UpperCamelCase`, and services/screens stay under `frontend/lib/services/` and `frontend/lib/screens/`. Prefer existing patterns.

## Testing Guidelines

Backend tests use Go's standard `testing` package and live beside package code. Add focused tests for auth, storage, event, handler, and thumbnail changes. Flutter tests use `flutter_test` in `frontend/test/`. Run the relevant layer tests before submitting; run `go test ./...` plus `flutter test` for cross-layer work.

## Commit & Pull Request Guidelines

Recent commits use short, lowercase, imperative-style subjects such as `update oidc for supporting native app` and `fix the formatting issue`. Keep commits focused and describe user-visible behavior. Pull requests should include a summary, test results, linked issues or context, and screenshots for UI changes. Note configuration, auth, storage, or migration impacts.

## Security & Configuration Tips

Do not commit `.env`, `.data/`, credentials, MinIO data, or generated secrets. Use `.env.example` and documented environment variables as templates. Treat proxy and `AUTH_MODE` changes carefully; trusted-header mode is only safe behind a proxy that strips inbound identity headers.
