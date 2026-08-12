# Identity Provider Configuration

How to configure an external identity provider (IdP) for `AUTH_MODE=oidc`, and
how to find the values Reliquary needs from it.

For the auth modes themselves, see [Authentication](authentication.md).

## What Reliquary Needs

| Variable | Where it comes from |
|----------|--------------------|
| `OIDC_ISSUER_URL` | The IdP's issuer, matching the `iss` claim in issued tokens exactly |
| `OIDC_CLIENT_ID` | The client/application ID registered for Reliquary |
| `OIDC_AUDIENCE` | The `aud` claim the IdP stamps into access tokens; defaults to `OIDC_CLIENT_ID` |
| `OIDC_USERNAME_CLAIM` | The claim carrying the username, default `preferred_username` |
| `OIDC_REDIRECT_URI` | The native redirect URI, default `com.reliquary.app://callback` |

Reliquary registers as a **public client using PKCE** — there is no client
secret. The backend brokers the authorization-code exchange through
`/api/auth/oidc/token` so the browser never makes a cross-origin call to the
IdP, but the exchange is still public-client PKCE.

## Verify Your Tokens First

Every value below is ultimately whatever your IdP actually puts in the token.
Read it off a real one rather than trusting a screenshot in any documentation,
including this page.

Sign in through the Reliquary web app, then in DevTools → Application → Local
Storage copy `flutter.jwt_token`. That is the access token the frontend sends
as its `Authorization: Bearer` credential. Decode the payload:

```bash
TOKEN='eyJ...'
python3 -c 'import sys,json,base64; p=sys.argv[1].split(".")[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))),indent=2))' "$TOKEN"
```

Check four fields:

| Claim | Must be |
|-------|---------|
| `iss` | Byte-identical to `OIDC_ISSUER_URL`, trailing slash included |
| `aud` | Your `OIDC_AUDIENCE`; may be a string or an array, any entry may match |
| `azp` | Normally the client ID — confirms the token came from Reliquary's own client |
| `preferred_username` | The value you want as the Reliquary username, or set `OIDC_USERNAME_CLAIM` to whichever claim holds it |

If the value in local storage is not three dot-separated segments — just an
opaque random string — your IdP does not issue JWT access tokens. See
[IdPs With Opaque Access Tokens](#idps-with-opaque-access-tokens).

## Why The Audience Matters

Reliquary validates that the access token names *it* in the `aud` claim. Without
that check, any access token your IdP minted for any client would authenticate
to Reliquary: a user signs into some other application on the same IdP, and that
application's token replays against Reliquary as that user, reaching both the
API and `/storage/*` downloads.

Validating the audience is what confines a token to the application it was
issued for. This is why `OIDC_AUDIENCE` must match reality — a value that is
merely plausible fails closed and nobody can log in.

## Authentik

Authentik is the reference setup; the local dev environment uses it (see
[Local OIDC Test With Mind Palace](local-oidc-test-with-mind-palace.md)).

Under **Applications → Providers**, create or edit an **OAuth2/OpenID
Provider**:

| Field | Value |
|-------|-------|
| Client type | **Public** — Reliquary uses PKCE and holds no secret |
| Client ID | Copy to `OIDC_CLIENT_ID` |
| Redirect URIs | See below — both a web and a native entry are required |
| Scopes | `openid`, `profile`, `email` — `profile` supplies `preferred_username` |
| Signing Key | Must be set, otherwise tokens cannot be verified |
| Issuer mode | Determines `OIDC_ISSUER_URL`, see below |

### Issuer URL

With the default issuer mode — *"Each provider has a different issuer, based on
the application slug"* — the issuer is:

```text
https://authentik.example.com/application/o/<application-slug>/
```

The trailing slash is part of it. If the provider is set to *"Same identifier
for all providers"* instead, the issuer is the Authentik root and
`OIDC_ISSUER_URL` must drop the `/application/o/<slug>/` path. Getting this
wrong rejects every token with an issuer mismatch, so confirm against the `iss`
claim of a decoded token.

### Audience

Authentik populates `aud` with the provider's client ID, so `OIDC_AUDIENCE`
does not need to be set — leaving it unset defaults it to `OIDC_CLIENT_ID`.
Confirm with a decoded token before relying on it.

Set `OIDC_AUDIENCE` explicitly only if a custom property mapping on the provider
overrides `aud`.

### Redirect URIs

Register both, since the same provider serves web and native clients:

```text
com.reliquary.app://callback
^http://localhost:[0-9]+/callback$
```

The first is `OIDC_REDIRECT_URI`, used by Android and by desktop loopback. The
second is the web build; use an exact `https://reliquary.example.com/callback`
in production rather than a localhost pattern.

### Resulting Configuration

```env
AUTH_MODE=oidc
OIDC_ISSUER_URL=https://authentik.example.com/application/o/reliquary/
OIDC_CLIENT_ID=reliquary
OIDC_USERNAME_CLAIM=preferred_username
OIDC_REDIRECT_URI=com.reliquary.app://callback
```

## Keycloak

Keycloak does **not** put the client ID in `aud` by default — access tokens are
issued with `aud: account`. Add an audience mapper, or authentication fails
closed for every user.

On the client, go to **Client scopes → `<client>-dedicated` → Add mapper → By
configuration → Audience** and set *Included Client Audience* to the client.
Ensure *Add to access token* is on.

Then either leave `OIDC_AUDIENCE` unset (it defaults to the client ID, which the
mapper now emits) or set it to the mapper's value.

```env
OIDC_ISSUER_URL=https://keycloak.example.com/realms/myrealm
OIDC_CLIENT_ID=reliquary
```

Keycloak's issuer has **no** trailing slash. The client must have *Standard
flow* enabled, *Client authentication* off (public), and PKCE method `S256`.

## Authelia

Authelia declares audiences explicitly per client in `configuration.yml`:

```yaml
identity_providers:
  oidc:
    clients:
      - client_id: reliquary
        public: true
        audience:
          - reliquary
        redirect_uris:
          - com.reliquary.app://callback
          - https://reliquary.example.com/callback
        scopes: [openid, profile, email]
        pkce_challenge_method: S256
```

Set `OIDC_AUDIENCE` to one of the `audience` entries.

## Zitadel

Zitadel puts both the project ID and the client ID in `aud`, so either works as
`OIDC_AUDIENCE`. The client ID is the more specific choice.

## IdPs With Opaque Access Tokens

Google, and Okta in its default configuration, issue access tokens that are
random strings rather than JWTs. They carry no claims, so no audience check is
possible locally — the token can only be validated by handing it back to the
provider, which answers "this token is valid" without answering "valid *for
you*".

Reliquary rejects these by default. To accept them anyway:

```env
OIDC_ALLOW_OPAQUE_TOKENS=true
```

This restores the pre-validation behaviour and its exposure: any access token
that provider issued, for any client, authenticates to Reliquary. Only use it
where every client registered at that IdP is equally trusted. The backend logs a
warning at startup while it is on.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `401`, `id token issued by a different provider` | `iss` mismatch | Compare `OIDC_ISSUER_URL` against the decoded `iss`, including the trailing slash and the Authentik issuer mode |
| `401`, `expected audience "x" got ["y"]` | `aud` mismatch | Set `OIDC_AUDIENCE` to the logged actual value, or add an audience mapper |
| `401`, `access token is not a JWT` | Opaque access token | See [IdPs With Opaque Access Tokens](#idps-with-opaque-access-tokens) |
| `401`, `failed to verify signature` | Wrong or rotated signing key | Confirm the provider's signing key is published at its `jwks_uri` |
| `401` only after some minutes of use | Expired token, refresh failing | Confirm `offline_access` is granted so a refresh token is issued |
| `userinfo missing claim` | Claim absent or misnamed | Grant the `profile` scope, or point `OIDC_USERNAME_CLAIM` at a claim the token actually carries |
| `502` from `/api/auth/oidc/discovery` | Backend cannot reach the issuer | The issuer URL must resolve from **inside** the API container *and* from the browser; a `localhost` issuer satisfies only one of the two |
| Login redirects then fails silently | Redirect URI not registered | Register the exact URI, web and native both |

Audience and issuer mismatches log the value the token actually carried next to
the expected one, and every OIDC rejection logs `expected_audience`. Neither is
a secret, and without both a misconfigured mapper is indistinguishable from an
attack.

## Users And Roles

With OIDC, user lifecycle belongs to the IdP. Reliquary creates no local account
for an OIDC identity and its local user management (`/api/admin/users`) is
intended for `AUTH_MODE=full`.

OIDC identities are always assigned the `user` role — group and role claims are
not mapped — and the `/api/admin/*` endpoints are not registered in OIDC mode at
all. There is no administrative access in an OIDC deployment; enabling password
auth alongside it to get an admin account is refused at startup, because the two
providers would share one storage namespace. See
[Authentication](authentication.md#one-provider-at-a-time).

### Username Stability

The claim named by `OIDC_USERNAME_CLAIM` becomes the user's storage namespace
(`files/<username>/`). It must therefore be stable for the life of the account:

- Renaming a user at the provider makes their existing files unreachable.
- Reusing a freed username gives the new holder the previous holder's archive.

`preferred_username` is the default because it is readable, but most providers
allow it to change. If yours does, either prevent renames operationally or point
`OIDC_USERNAME_CLAIM` at an immutable claim such as `sub` — at the cost of
namespaces named after opaque identifiers.

Usernames must match `^[a-zA-Z0-9._-]{1,64}$`; anything else is rejected at
login rather than interpolated into an object key. Note this excludes email
addresses, so `email` is not usable as the username claim.
