# Local OIDC Test With Mind Palace Authentik

Reliquary's standalone frontend can be tested against the Mind Palace local
Authentik setup. This avoids duplicating Authentik inside the Reliquary-only
flake while still exercising the Reliquary OIDC backend and frontend login flow.

## Topology

Use the repository root dev environment:

- Authentik provides the OIDC issuer.
- The root Caddy proxy exposes Reliquary at `/api/reliquary`.
- The Reliquary backend runs with `AUTH_MODE=oidc`.
- The standalone Reliquary frontend runs on its own web-server port and uses
  the proxied Reliquary URL as its API base.

The root `bin/load-infra-env` exports:

```bash
AUTH_MODE=oidc
OIDC_ISSUER_URL="$AUTHENTIK_URL/application/o/mind-palace/"
OIDC_CLIENT_ID=mind-palace
OIDC_REDIRECT_URI=com.reliquary.app://callback
RELIQUARY_URL="http://localhost:$PROXY_PORT/api/reliquary"
```

## Run

From the repository root:

```bash
nix develop
start-infra
```

Wait until Authentik setup finishes. In another terminal:

```bash
nix develop
dev
```

This starts the Reliquary backend in OIDC mode as part of the Mind Palace dev
process-compose session.

In a third terminal:

```bash
nix develop
start-reliquary-frontend
```

The frontend starts on:

```text
http://localhost:3001
```

Open that URL and choose `SIGN_IN_WITH_OIDC`.

Default local Authentik admin credentials:

```text
akadmin / mind-palace-admin
```

## Notes

- The local Authentik provider is configured with public client ID
  `mind-palace`.
- The web OIDC redirect URI is `/callback`, matching the local Authentik
  redirect regex for `http://localhost:.*/callback`.
- Android OIDC testing uses the native app redirect URI advertised by Reliquary,
  defaulting to `com.reliquary.app://callback`. Register this exact URI with
  Authentik. The local Mind Palace dev setup includes it for newly created
  providers.
- Linux and macOS desktop OIDC testing still uses a temporary loopback redirect with the
  `http://localhost:<port>/callback` form, matching the local Authentik
  redirect regex.
- Browser XHR for OIDC discovery and token exchange goes through Reliquary's
  same-origin `/api/auth/oidc/*` helper endpoints. The browser still navigates
  to Authentik for the login page, but it does not require Authentik to allow
  cross-origin discovery or token requests.
- This test path validates the standalone Reliquary frontend's OIDC button,
  PKCE redirect flow, token exchange, bearer-token API calls, and backend
  userinfo validation.
- It does not test password login; use a Reliquary-only `AUTH_MODE=full`
  deployment for that path.
