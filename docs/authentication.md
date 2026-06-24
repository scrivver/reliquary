# Authentication

Reliquary supports multiple authentication modes.

| Mode | Use case | Auth | User identity |
|------|----------|------|---------------|
| `full` | Standalone deployment | JWT login | From JWT token |
| `oidc` | External identity provider | OIDC access token | From configured OIDC userinfo claim |
| `proxy` | Legacy trusted proxy deployment | None in Reliquary | From `X-Reliquary-User` header |
| `none` | Single-user scripts or embedded use | None | Fixed default user |

The frontend discovers enabled login methods from:

```http
GET /api/auth/config
```

`AUTH_MODE` keeps existing deployments working. Provider flags can enable
combined modes, for example password login and OIDC login together:

```env
AUTH_PASSWORD_ENABLED=true
AUTH_OIDC_ENABLED=true
```

## Mixed Mode

To let users sign in with either a local password or an external OIDC provider,
use `AUTH_MODE=oidc` with password enabled, or `AUTH_MODE=full` with OIDC
enabled:

```env
AUTH_MODE=oidc
AUTH_PASSWORD_ENABLED=true
JWT_SECRET=unique-random-secret
AUTH_USERNAME=admin
AUTH_PASSWORD=change-me-in-production

OIDC_ISSUER_URL=https://auth.example.com/application/o/my-app/
OIDC_CLIENT_ID=my-app
```

The frontend discovers both methods from `/api/auth/config` and shows both
login options. API requests are accepted with either a Reliquary-issued JWT
or a valid OIDC access token.

## Password Auth

`AUTH_MODE=full` enables local username/password login with Reliquary-issued
JWTs. The initial admin is configured with:

```env
AUTH_USERNAME=admin
AUTH_PASSWORD=change-me-in-production
JWT_SECRET=unique-random-secret
```

The default development credentials are `admin` / `admin`.

## OIDC Auth

`AUTH_MODE=oidc` enables OIDC bearer-token authentication and frontend OIDC
login.

Relevant configuration:

| Variable | Description |
|----------|-------------|
| `OIDC_ISSUER_URL` | OIDC issuer URL |
| `OIDC_CLIENT_ID` | Public OIDC client ID used by the frontend |
| `OIDC_REDIRECT_URI` | Native app redirect URI advertised to mobile clients |
| `OIDC_USERNAME_CLAIM` | Userinfo claim used as the Reliquary username |

When OIDC is used, user lifecycle and password management belong to the
identity provider. Reliquary local-user management is intended for full auth
mode.

## Proxy Auth

Proxy auth is a legacy or advanced deployment mode. Reliquary must only be
reachable through a trusted proxy, and the proxy must strip inbound
`X-Reliquary-User` before setting its own value.

Example nginx snippet:

```nginx
location / {
    proxy_set_header X-Reliquary-User $remote_user;
    proxy_pass http://127.0.0.1:2080;
}
```

## None Auth

`AUTH_MODE=none` disables login. All files belong to the default user.

```bash
AUTH_MODE=none MINIO_PORT=9000 go run .
```
