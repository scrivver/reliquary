# Changelog

All notable changes to Reliquary are documented in this file.

## [v0.5.0] - 2026-09-02

### Fixed

- **Lost updates to the user store**: `admin/users.json` is rewritten whole on
  every change, and it has two writers — the API server and `reliquary-user`.
  A writer working from a stale snapshot did not drop one field; it restored its
  entire snapshot over everything written since it loaded, with no error and no
  log line. A password change could be silently reverted, leaving the superseded
  password working; a deactivated account could come back live; an account
  created by the CLI could disappear.

  Every mutation is now conditional on the ETag it was derived from and retries
  against a freshly read snapshot on conflict, so a stale write is refused
  rather than silently winning. Two races are closed as a side effect:
  concurrent `Create` of the same username now yields one success and one clean
  error instead of two apparent successes, and replicas racing to seed the first
  admin produce exactly one account.

  The defect was reachable in two directions with different exposure. A CLI
  invocation overlapping an API mutation is a sub-second window. The reverse —
  an API mutation within the 30s reload interval *after* a CLI run has already
  exited — is far wider and needs no overlap at all, which makes a routine
  `reliquary-user create-user` against a live server the most likely way to have
  hit this.

- **Publisher never reconnected**: the user-store change publisher connected
  once at startup and had no recovery path, so a broker restart, or a cold start
  where RabbitMQ answers its healthcheck before definitions are applied, would
  disable change announcements for the life of the process. It now connects on
  first use and reconnects after a failure, matching the subscriber.

- **Documented settings were not wired into Compose**: `USER_SYNC_ENABLED`,
  `USER_SYNC_EXCHANGE`, and `STORAGE_INSECURE_SKIP_CAS_PREFLIGHT` are now passed
  through to the container in both Compose files. Without this, setting them in
  `.env` had no effect — which would have been worst for the preflight escape
  hatch, needed precisely when the API refuses to start.

### Added

- **User store invalidation**: after a successful write the new version is
  announced on a new `reliquary.userstore` fanout exchange, so other replicas
  reload within a round trip instead of waiting out the 30s periodic reload.
  Strictly an optimisation — correctness comes from the conditional write.
  Publishes are non-mandatory and transient, a failure to announce never fails
  the mutation, and the periodic reload remains the backstop. Each replica
  declares its own exclusive, auto-delete queue at runtime; this is the one
  queue not predeclared in the infrastructure definitions, because it exists
  only for the life of one connection.

- **Conditional write preflight**: the API and `reliquary-user` verify at
  startup that the object storage backend actually enforces `If-Match` and
  `If-None-Match`, and refuse to start if it does not. A backend that accepts
  the headers and ignores them is the dangerous case — writes succeed, no error
  is raised, and the lost updates return silently with every test still passing.
  `STORAGE_INSECURE_SKIP_CAS_PREFLIGHT=true` opts out, accepting that risk.
  Verified against MinIO; AWS S3 added both conditions in 2024.

- New `reliquary.userstore` exchange in both `infra/rabbitmq.nix` and
  `docker/rabbitmq-definitions.json`.

### Changed

- **A corrupt `admin/users.json` is now fatal at startup** rather than silently
  ignored. Previously an unparseable object left the store empty, `Seed` created
  a fresh admin, and the first write overwrote the corrupt object — destroying
  the account file. Refusing to boot is recoverable; that was not.

- `UserStore` takes a narrow storage interface instead of a concrete
  `*storage.Client`, so the persistence round trip is exercisable in tests. No
  behaviour change on its own; it is what made the defect above reproducible.

### Known Limitations

- `storage/file_index.go` and `storage/checksum_index.go` share the read-modify-
  rewrite design that caused this defect. Both are per-user, so contention is
  much lower, and neither has a second writer today. The conditional-write
  primitives they would need now exist; porting them is follow-up work.

## [v0.4.2] - 2026-08-14

### Fixed

- **Stale frontend after upgrade**: the bundled ingress served `index.html`,
  `flutter_bootstrap.js`, `flutter_service_worker.js`, `main.dart.js`, and
  `version.json` without a `Cache-Control` directive. Flutter does not
  content-hash those files, so browsers applied heuristic caching and kept
  running the previous bundle against the upgraded API. The failure was hard to
  read: only calls whose contract had changed broke, so `/api/*` kept working
  while `/storage/*` downloads returned `invalid token` — a pre-`v0.4.0` bundle
  fetches thumbnails with `Image.network`, which sends no `Authorization`
  header for the edge check added in `v0.4.0`. These files are now served
  `no-cache`, which still permits a `304`. Browsers that cached the old bundle
  need one hard reload to pick this up.

### Changed

- The development (`infra/caddy.nix`) and all-in-one (`nix/container.nix`)
  proxy configs now strip the `Authorization` header explicitly with
  `header_up -Authorization`, matching the bundled ingress. They previously
  relied on `copy_headers Authorization` clearing it as a side effect of
  copying an absent header from the auth response — correct, but stated three
  different ways across four files, which is how the `v0.4.1` bug reached a
  release.

### Documentation

- New "Object Storage And Bandwidth" section in `docs/deployment.md` covering
  which components carry file bytes, and why remote object storage (R2, S3)
  requires the ingress to run somewhere with high egress rather than on a home
  uplink. Includes a complete R2 configuration.
- The bare-metal Caddyfile now states that the `/storage/*` block is a security
  control that fails open if omitted, and points at the bundled ingress as the
  supported path.
- New `docs/direct-storage-download-plan.md`, a rejected-for-now proposal to
  serve bytes directly from object storage, recorded with its trade-offs and
  the alternatives considered.

## [v0.4.1] - 2026-08-14

### Fixed

- **Downloads through the bundled ingress**: every `/storage/*` request reached
  MinIO carrying both the presigned query signature and the caller's
  `Authorization` header, and MinIO rejects that combination with `request has
  multiple authentication types`. Caddy now strips the header after
  `forward_auth` has consumed it. The header is still required for the edge
  check itself, so downloads continue to fail closed without a valid session.

## [v0.4.0] - 2026-08-14

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
