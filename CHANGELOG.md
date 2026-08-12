# Changelog

All notable changes to Reliquary are documented in this file.

## [Unreleased]

### Security

- **Proxy auth**: `AUTH_MODE=proxy` no longer trusts the `X-Reliquary-User`
  header on its own. The upstream proxy must now present
  `AUTH_PROXY_SHARED_SECRET` in the `X-Reliquary-Proxy-Secret` header;
  unverified requests are rejected with `401`. Previously any client that could
  reach the API directly could assert any identity, and a request with **no**
  identity header fell back to `AUTH_USERNAME` (the admin account) rather than
  being denied — so a proxy-mode deployment whose API was reachable outside the
  proxy served the admin's namespace to anonymous callers. The same middleware
  guards the `/api/auth/check` edge check, so `/storage/*` downloads fail closed
  too.
- **Proxy auth**: The identity asserted by the proxy is now validated against
  `^[a-zA-Z0-9._-]{1,64}$` before it is used as an object key prefix, so a
  compromised or misconfigured upstream cannot escape a user's storage
  namespace.

### Changed

- **BREAKING — proxy auth**: The backend refuses to start with
  `AUTH_MODE=proxy` unless `AUTH_PROXY_SHARED_SECRET` is set. Configure the
  upstream proxy to send the secret, or set
  `AUTH_PROXY_INSECURE_TRUST_HEADER=true` if the API is reachable only from the
  proxy — in which case inbound `X-Reliquary-User` must be stripped at every hop
  in front of the backend. `AUTH_USERNAME` is no longer used as a fallback
  identity in proxy mode; it still seeds the initial admin and still serves as
  the default user for `AUTH_MODE=none`.
- **Proxy auth**: Enabling proxy auth alongside password or OIDC auth now logs a
  startup warning. Proxy auth only takes effect when both of the others are
  disabled; otherwise `X-Reliquary-User` was, and still is, ignored.

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
