# Reliquary Auth Capabilities and Frontend Flow Plan

## Context

Reliquary currently supports several backend auth modes:

- `full`: standalone username/password login with Reliquary-issued JWTs.
- `oidc`: bearer-token validation against an OIDC provider.
- `proxy`: trusted upstream auth proxy that injects `X-Reliquary-User`.
- `none`: single-user/no-auth mode.

For the Mind Palace platform, OIDC is the first-class identity provider. The
root Mind Palace app logs in through Authentik and sends the same access token
to Reliquary and Engram. Engram multi-tenancy depends on the same stable
username being used across both services.

For standalone Reliquary, username/password login should remain first class.
OIDC should also remain first class. Proxy auth should be treated as a legacy or
advanced deployment mode, not a primary frontend experience.

## Goals

- Keep standalone username/password auth.
- Keep first-class OIDC auth.
- Allow password auth and OIDC to be enabled at the same time.
- Add an explicit unauthenticated backend endpoint for frontend auth discovery.
- Improve the frontend startup flow for web and native/mobile separately.
- Treat proxy auth as legacy/advanced and document its limitations.
- Preserve the tenant identity invariant used by Reliquary and Engram.

## Non-Goals

- Do not remove username/password auth.
- Do not remove OIDC auth.
- Do not make proxy auth a primary login option.
- Do not expose any OIDC client secret to the frontend.
- Do not require the web frontend to support arbitrary user-entered API URLs.

## Backend Capability Endpoint

Add a public endpoint:

```http
GET /api/auth/config
```

The endpoint should return public auth capabilities:

```json
{
  "password": {
    "enabled": true
  },
  "oidc": {
    "enabled": true,
    "issuer_url": "https://auth.example.com/application/o/reliquary/",
    "client_id": "reliquary",
    "username_claim": "preferred_username"
  },
  "proxy": {
    "enabled": false,
    "legacy": true
  },
  "none": {
    "enabled": false
  }
}
```

Only public OIDC data should be returned. If a confidential OIDC client is ever
added for a server-side flow, its secret must remain backend-only.

`/api/health` should remain a health/liveness endpoint. Auth discovery belongs
in `/api/auth/config`.

## Backend Configuration

Keep backward compatibility with the existing `AUTH_MODE` values:

- `AUTH_MODE=full`: password only.
- `AUTH_MODE=oidc`: OIDC only.
- `AUTH_MODE=proxy`: proxy only, legacy.
- `AUTH_MODE=none`: no auth only.

Introduce provider-oriented configuration for combined modes:

```env
AUTH_PASSWORD_ENABLED=true
AUTH_OIDC_ENABLED=true
AUTH_PROXY_ENABLED=false
AUTH_NONE_ENABLED=false
OIDC_ISSUER_URL=https://auth.example.com/application/o/reliquary/
OIDC_CLIENT_ID=reliquary
OIDC_REDIRECT_URI=com.reliquary.app://callback
OIDC_USERNAME_CLAIM=preferred_username
```

Implementation can initially derive these booleans from `AUTH_MODE`, then allow
explicit provider flags to override or extend the old mode.

## Backend Routing Model

Password auth should keep:

```http
POST /api/login
```

OIDC auth should continue accepting:

```http
Authorization: Bearer <access_token>
```

When both password and OIDC are enabled, protected API routes should accept
either a Reliquary JWT or a valid OIDC access token.

Admin behavior needs an explicit decision:

- Password auth already has roles from the Reliquary user store.
- OIDC currently maps all users to normal users.
- A later role/group mapping can promote OIDC users to admin.

Until that mapping exists, OIDC users should remain non-admin.

## Frontend Web Flow

The web frontend should use the same-origin deployment model:

- Do not show an editable server URL on the web login screen.
- Call `/api/auth/config` from the same origin.
- Render login methods from the returned capabilities.
- Resolve API and storage paths relative to the deployed origin.

This matches the current Reliquary deployment model, where the web frontend,
API, and storage proxy are served behind the same public service.

Web startup flow:

```text
load app
fetch /api/auth/config
if none.enabled:
    enter app
else if proxy.enabled and no first-class login methods:
    enter app, because the upstream proxy owns login
else if existing session/token is valid:
    enter app
else:
    show login screen with enabled methods
```

## Frontend Native and Mobile Flow

Native/mobile/desktop builds should require a server URL before showing login.

Startup flow:

```text
load app config
if no saved server URL:
    show server setup screen
else:
    fetch <server>/api/auth/config
    continue to auth flow
```

Server setup behavior:

- User enters a Reliquary server URL.
- App calls `<server>/api/auth/config`.
- Save the URL only after the capability request succeeds.
- Then show the login screen using the discovered capabilities.

Native/mobile login behavior:

- Show username/password fields when `password.enabled` is true.
- Show an OIDC login button when `oidc.enabled` is true.
- Use Authorization Code + PKCE for OIDC.
- Store tokens securely where the platform supports it.
- Attach the OIDC access token to API requests as a bearer token.

If the server reports only proxy auth, native/mobile should show an unsupported
message unless a dedicated proxy-cookie browser flow is designed later.

## Proxy Auth Legacy Treatment

Proxy auth should remain as an advanced compatibility mode for deployments that
already rely on an upstream authentication proxy.

It should not be treated as a primary login method in the frontend.

Documentation should state:

- Reliquary must not be directly reachable except through the trusted proxy.
- The proxy must strip inbound `X-Reliquary-User` headers from clients.
- The proxy must set `X-Reliquary-User` to a stable username.
- Proxy users are currently normal users unless role mapping is added later.
- The current default-user fallback is convenient but risky for multi-user
  proxy deployments.

## Tenant Identity Invariant

Reliquary and Engram both depend on a stable shared username.

Reliquary stores files under:

```text
files/<username>/...
thumbs/<username>/...
<username>/checksums.json
```

Reliquary also stamps uploaded objects with owner metadata. Engram ingestion
copies that owner into Postgres, and the Engram API filters queries by the
authenticated OIDC username.

Therefore:

```text
Reliquary resolved username == Engram resolved username == object owner
```

For OIDC, `OIDC_USERNAME_CLAIM` must be chosen carefully. In the Mind Palace
platform this is currently `preferred_username`.

## Migration Notes

Migrating from password auth to OIDC is straightforward when the OIDC username
claim matches the old Reliquary username.

Example:

```text
old Reliquary user: alice
OIDC preferred_username: alice
```

In that case, existing object prefixes and Engram ownership continue to line up.

If the OIDC username changes, for example:

```text
old Reliquary user: alice
OIDC preferred_username: alice@example.com
```

then migration must account for:

- Reliquary object prefixes: `files/alice/...`.
- Reliquary thumbnails: `thumbs/alice/...`.
- Reliquary checksum index: `alice/checksums.json`.
- MinIO object owner metadata.
- Engram `files.owner`.
- Engram `files.file_path` if object keys are renamed.

Proxy auth has the same tenant-identifier problem as OIDC. It only changes
where the username comes from.

## Implementation Steps

1. Add backend auth capability config structs.
2. Add `GET /api/auth/config`.
3. Keep `AUTH_MODE` compatibility.
4. Add provider flags for combined password and OIDC mode.
5. Update protected route middleware to accept enabled auth providers.
6. Add OIDC login support to the Reliquary frontend using PKCE.
7. Replace frontend `getAuthMode()` with capability discovery.
8. Split web and native server URL behavior.
9. Update settings/login UI so web does not expose server URL editing.
10. Add native/mobile server setup before login.
11. Mark proxy auth as legacy in docs.
12. Add tests for capability responses and frontend capability parsing.

## Verification

Backend:

```bash
cd reliquary/backend
go test ./...
```

Frontend:

```bash
cd reliquary/frontend
flutter analyze
flutter test
```

Manual verification matrix:

- Password-only backend shows username/password login.
- OIDC-only backend shows OIDC login.
- Combined password and OIDC backend shows both.
- Web build uses same-origin API discovery.
- Native/mobile build requires server URL before login.
- Proxy-only backend is treated as legacy/advanced.
- `none` mode enters the app without login.
