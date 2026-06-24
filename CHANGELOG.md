# Changelog

All notable changes to Reliquary are documented in this file.

## [v0.3.0] - 2026-06-24

### Added

- **Auth**: Reliquary-issued JWTs now include a `source` claim (`"password"`) so
  consumers can distinguish password-issued tokens from OIDC tokens without
  relying on heuristics.
- **Auth**: Documented mixed authentication mode — `AUTH_MODE=oidc` combined
  with `AUTH_PASSWORD_ENABLED=true` allows both local password login and
  external OIDC login in the same deployment.

### Changed

- **Dev environment**: Unified infrastructure and dev-shell definitions in
  `flake.nix`, simplifying `bin/dev` and the backend/frontend startup scripts.
  `bin/load-infra-env` now exports infrastructure ports automatically.
- **Docs**: Expanded README with deployment overview, feature list, and preview
  screenshots.

### Fixed

- Minor README typo and outdated identical-file-upload description.

## [v0.2.0] - earlier

- Initial tracked release.
