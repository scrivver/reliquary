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

`AUTH_MODE` keeps existing deployments working, and the provider flags
(`AUTH_PASSWORD_ENABLED`, `AUTH_OIDC_ENABLED`, `AUTH_PROXY_ENABLED`,
`AUTH_NONE_ENABLED`) override what it implies.

## One Provider At A Time

Password and OIDC auth **cannot be enabled together**; the backend refuses to
start if both are on.

Both map a bare username onto the same flat storage namespace —
`files/<username>/` and friends — with no record of which provider an identity
came from. Run them side by side and an OIDC identity whose username happens to
be `admin` addresses the local admin's files, and is authorized for them by
every ownership check including the `/storage/*` edge check. Keeping exactly one
provider active means a namespace has exactly one claimant.

The same reasoning already applies to proxy auth, which only takes effect when
password and OIDC auth are both disabled.

Note that this also holds **across** a deployment's lifetime, where the backend
cannot enforce it: switching a running deployment from password auth to OIDC
hands `files/alice/` to whichever `alice` the identity provider supplies. Move
or delete the existing namespaces first if the two are different people.

## Password Auth

`AUTH_MODE=full` enables local username/password login with Reliquary-issued
JWTs. The initial admin is configured with:

```env
AUTH_USERNAME=admin
AUTH_PASSWORD=change-me-in-production
JWT_SECRET=unique-random-secret
```

The default development credentials are `admin` / `admin`.

### Session Revocation

Tokens are valid for 72 hours, but every authenticated request re-checks the
account behind the token, so a session can be ended before its token expires:

| Action | Effect on existing tokens |
|--------|---------------------------|
| Deactivate user | Rejected immediately |
| Delete user | Rejected immediately |
| Change password | Rejected immediately (all of that user's sessions) |
| Change role | Applies immediately; no re-login needed |

Password changes and deactivations bump a per-user token version that each token
records at login, so tokens issued earlier no longer match. Because
`/api/auth/check` runs under the same middleware, revocation also covers
`/storage/*` downloads.

Changing your own password is therefore how you sign out a device you no longer
control. It goes through `PUT /api/users/me/password`, which requires the
current password and returns a replacement token so the client making the change
stays signed in. Admins reset *other* users' passwords through
`PUT /api/admin/users/{username}/password`, and change their own the same way
everyone else does. See the [API Reference](api-reference.md#password-changes).

The account state behind these checks is held in memory and re-read from object
storage every 30 seconds. In a deployment running more than one API replica, a
revocation performed on one replica therefore takes effect on the others within
that interval.

## OIDC Auth

`AUTH_MODE=oidc` enables OIDC bearer-token authentication and frontend OIDC
login.

Relevant configuration:

| Variable | Description |
|----------|-------------|
| `OIDC_ISSUER_URL` | OIDC issuer URL |
| `OIDC_CLIENT_ID` | Public OIDC client ID used by the frontend |
| `OIDC_AUDIENCE` | Expected `aud` claim; defaults to `OIDC_CLIENT_ID` |
| `OIDC_ALLOW_OPAQUE_TOKENS` | Accept non-JWT access tokens, which cannot be audience-checked |
| `OIDC_REDIRECT_URI` | Native app redirect URI advertised to mobile clients |
| `OIDC_USERNAME_CLAIM` | Userinfo claim used as the Reliquary username |

Access tokens are verified against the issuer's keys and must name Reliquary in
their `aud` claim, so a token minted for a different application on the same
provider is rejected. See
[Identity Provider Configuration](idp-configuration.md) for how to find these
values and for per-provider setup.

When OIDC is used, user lifecycle and password management belong to the
identity provider. Reliquary local-user management is intended for full auth
mode, and the `/api/admin/*` endpoints are **not registered** in OIDC mode —
including aggregate storage analytics. Group and role claims are not mapped, so
every OIDC identity gets the `user` role.

Revocation is the provider's responsibility in this mode, and it is bounded by
the access token's lifetime rather than applied on the spot: access tokens are
verified locally against the issuer's keys, so a token revoked at the provider
keeps working until it expires. Keep access-token lifetimes short.

The username claim becomes the user's storage namespace, so it must be stable:
renaming a user at the provider makes their existing files unreachable, and
reusing a freed username hands the new holder the previous holder's archive.
Prefer a claim the provider guarantees never changes.

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
