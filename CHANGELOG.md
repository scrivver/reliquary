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
- **OIDC**: Access tokens are now verified against the issuer's signing keys and
  must name Reliquary in their `aud` claim. Previously authentication was
  delegated entirely to the provider's userinfo endpoint, which only answers
  "this token is valid" and never "valid for Reliquary" — so **any** access
  token the issuer had minted for **any** client registered with it
  authenticated here as that user, through both the API and `/storage/*`
  downloads. The expected audience defaults to `OIDC_CLIENT_ID` and can be
  overridden with `OIDC_AUDIENCE` for providers that stamp something else.
  Tokens failing verification are rejected outright; there is no userinfo
  fallback, which would have restored the same hole. Userinfo is still used to
  resolve the username when the verified token does not carry the claim.
- **OIDC**: Opaque (non-JWT) access tokens carry no claims and cannot be
  audience-checked, so they are now rejected unless
  `OIDC_ALLOW_OPAQUE_TOKENS=true` is set explicitly. That flag restores the
  previous behaviour and its exposure, and logs a warning at startup.
- **OIDC**: Cached identities are capped at the access token's own `exp`. A
  token could previously keep working for up to five minutes past expiry.
- **Auth**: Password and OIDC auth can no longer be enabled together. Both map a
  bare username onto the same flat storage namespace (`files/<username>/`) with
  no record of the provider an identity came from, so an OIDC identity whose
  username happened to be `admin` addressed the local admin's files and passed
  every ownership check, including the `/storage/*` edge check. Enabling both
  now fails at startup.
- **Auth**: Reliquary-issued JWTs are now checked against the account they name
  on every request, instead of being trusted for their full 72-hour lifetime on
  the strength of their signature alone. Deactivating a user, deleting a user,
  or changing a password now ends that user's existing sessions immediately;
  previously all three left every issued token working for up to three days,
  including for `/storage/*` downloads via the edge check. Role changes also
  apply immediately, since the role is now read from the stored account rather
  than from the token's claim.
- **Auth**: Password changes and deactivations bump a per-user `token_version`
  recorded in each token at login. Accounts and tokens predating this field both
  carry version 0, so existing sessions survive the upgrade.
- **Rate limiting**: `X-Forwarded-For` is now believed only from a peer listed
  in `TRUSTED_PROXIES` (default: loopback and private ranges), and the chain is
  read right to left so the client is the first hop that is not itself a
  trusted proxy. Previously the header was taken from any peer and parsed with
  `net.SplitHostPort`, which fails on the bare addresses the header actually
  carries — so a comma-separated chain became the map key verbatim, and
  rotating it drew a fresh quota on every request. The bundled deployments were
  not exposed: Caddy discards inbound `X-Forwarded-*` by default and the API
  publishes no ports, so the limit held. The gap was the backend having no
  protection of its own — it opened as soon as the API was reachable directly
  (`LISTEN_ADDR` on a TCP port), or as soon as Caddy's `trusted_proxies` was
  configured to put a CDN or TLS terminator in front, which makes Caddy forward
  the client's unverified chain. Malformed entries are a startup error rather
  than a silently dropped range.
- **Downloads**: The `/storage/*` edge check now rejects non-canonical object
  keys and requires the bucket segment it anchors on. The forwarded request URI
  is percent-decoded before the namespace prefix is compared, so a request for
  `files/alice%2f..%2f..%2ffiles%2fbob%2fx.jpg` decoded to a key naming another
  user's object while still passing the `files/alice/` prefix test — the check
  answered "allow" for a file the caller did not own. MinIO refused to serve
  the object independently (`XMinioInvalidResourceName`), so this was not
  exploitable end to end, but the authorization decision itself was wrong. A
  missing bucket segment was also silently tolerated, yielding a key that named
  a different object than the request did. Keys are rejected rather than
  normalized: Caddy forwards the raw path to MinIO, so a rewritten key would no
  longer be the key MinIO serves. The same canonical-key check now guards the
  ownership test used by presign, batch download, and delete.
- **Auth**: Usernames are validated against `^[a-zA-Z0-9._-]{1,64}$` wherever an
  identity enters the system — local account creation, the OIDC username claim
  (from the access token and from userinfo), and the proxy identity header.
  Previously only the proxy header was checked, so an identity provider that
  permits `/` in the username claim, or an admin creating a user named
  `../admin`, could address object keys outside that user's namespace.

### Fixed

- **Frontend**: An expired session no longer strands the user on a screen that
  cannot load. The `401` handler was an empty method deferring to a handler
  that was never written, so the token was cleared but nothing navigated: the
  screen showed a raw error, and every later request went out with no
  credential at all and failed too. Only a full page reload recovered. The app
  now returns to the login screen with "Your session expired. Please sign in
  again." This also covers sessions ended by a password change or a
  deactivation, which the API rejects the same way.
- **Frontend**: The stored token's `exp` is now checked before it is used, so a
  session that expired while the app was closed goes straight to the login
  screen instead of admitting the user and failing every request behind it.
  Tokens with no readable expiry — opaque OIDC access tokens — are still used
  until the server rejects them.
- **Frontend**: OIDC sessions now actually refresh. The refresh token was
  stored but never used: the renewal path only ran when the access token was
  *absent*, and the access token was only ever removed by signing out, so an
  expired one was returned indefinitely. Renewal now happens before a request
  when the token has expired, and once in response to a `401`, before the
  session is given up. Concurrent requests share a single refresh, so a
  provider that rotates refresh tokens does not invalidate its own retries.

### Added

- **Auth**: `PUT /api/users/me/password` — self-service password change for any
  authenticated user. It requires the current password, so a stolen token cannot
  be escalated into permanent ownership of the account, and it returns a
  replacement token so the calling client stays signed in while every other
  session for that account is signed out.
- **Auth**: The API re-reads the user store from object storage every 30
  seconds, so a deactivation or password change performed by one API replica
  applies on the others within that interval. Previously revocation would only
  have applied to the replica that handled the change.
- **Docs**: [Identity Provider Configuration](docs/idp-configuration.md) — how to
  read the issuer, audience, and username claim off a real token, plus
  per-provider setup for Authentik, Keycloak, Authelia, and Zitadel.

### Changed

- **BREAKING — OIDC**: The backend refuses to start with OIDC enabled unless
  `OIDC_CLIENT_ID` (or `OIDC_AUDIENCE`) is set, or
  `OIDC_ALLOW_OPAQUE_TOKENS=true` is given. Deployments that relied on
  userinfo-only validation must now supply the audience their provider issues.
  Most providers use the client ID, so setting `OIDC_CLIENT_ID` — already
  required for the login flow — is usually enough. See
  [Identity Provider Configuration](docs/idp-configuration.md) for how to
  confirm the value and for per-provider setup.
- **BREAKING — password changes**: `PUT /api/admin/users/{username}/password` is
  now purely administrative and rejects any attempt to change an admin account's
  password, including the caller's own. Changing your own password moves to
  `PUT /api/users/me/password`, which takes `current_password` and
  `new_password` instead of `password`. The previous endpoint documented itself
  as "admin or self", but was registered behind admin-only middleware, so the
  self-service branch was unreachable for non-admin users — a normal user could
  not change their own password at all. The settings screen already collected
  the current password without sending it; it now does.
- **BREAKING — mixed auth mode**: `AUTH_MODE=oidc` with
  `AUTH_PASSWORD_ENABLED=true` (and the reverse) is no longer supported and now
  refuses to start. Mixed mode was documented in v0.3.0; use password auth or
  OIDC alone. Because `/api/admin/*` is only registered when password auth is
  enabled, this means OIDC deployments have no admin endpoints, including
  aggregate storage analytics.
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
