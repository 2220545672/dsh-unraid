**English** · [中文](security.zh-CN.md)

# Security model

This document explains what the container does at the **network layer**. Users only need the conclusion: put it behind an edge that authenticates for you (or a trusted LAN), set `PUBLIC_URL` when needed, and **do not expose lan mode to the internet**.

## DSH's own browser trust fence

DSH has a check that prevents "the browser being manipulated by a third-party page" (implemented in its `dsh-client-connection` package):

- The request's `Host` must be **loopback**, the container's **listening bind address**, or an authority explicitly declared via `--trusted-host`;
- If the request carries an `Origin`, it must be same-origin with `Host`;
- Requests with `Sec-Fetch-Site: cross-site` are always rejected.

This gives `dsh web` two hard prerequisites: **it must not bind a wildcard address** (it must be given a concrete IP), and **there must be a proxy in front that knows the external authority**. This image's approach is: DSH listens only on `127.0.0.1:3080`, and the built-in Caddy listens on `8080` for the outside.

## The two modes

| | edge mode | lan mode |
|---|---|---|
| Trigger | `PUBLIC_URL` is set | `PUBLIC_URL` is empty |
| Host handling | rewritten to the authority of `PUBLIC_URL` | fixed to loopback |
| Origin handling | kept, and any Origin not equal to `PUBLIC_URL` is rejected | Origin is **stripped** |
| Arguments passed to DSH | `--public-url <origin> --trusted-host <authority>` (plus the entries in `DSH_TRUSTED_HOSTS`) | none |
| Applies to | reverse proxy + SSO, VPN, HTTPS entry | reachable only from trusted networks |

In both modes, DNS rebinding protection and cross-site protection remain in force:

- **rebinding** cannot forge a valid `Host` (edge mode requires equality with `PUBLIC_URL`, lan mode fixes it to loopback);
- **cross-site requests** are stopped by DSH's `Sec-Fetch-Site` rule and Origin validation.

lan mode has **no** notion of an "external authority", so it cannot provide correct Host/Origin determination for public access — that is why "do not expose it to the internet", not because a password layer is missing.

## Who may connect: `ALLOWED_CLIENTS`

The container keeps an allowlist at the proxy layer. Sources that are not on it **get no page at all** — the request never reaches DSH:

- **IPs or CIDRs** are compared against the connection's source address; **hostnames** against the request's `Host` header. The two can be mixed: `127.0.0.1,192.168.0.0/16,dsh.example.com`.
- **Loopback addresses are always allowed** (`127.0.0.1`, `::1` are added automatically) — the container's own health check goes over loopback, and without it the container would report unhealthy forever.
- Requests that are not on the allowlist get `403 Forbidden: this client is not listed in ALLOWED_CLIENTS`.
- Behind a reverse proxy the connection source is **the proxy's address**, so the proxy has to be on the list (from then on the proxy's own authentication decides who gets in). To decide by the **real client IP** instead, declare the proxy's network in `TRUSTED_PROXY_CIDRS`: Caddy then reads `X-Forwarded-For` for those sources only.
  ⚠️ **Never** put a network that untrusted clients can also originate from into `TRUSTED_PROXY_CIDRS` — that amounts to letting anyone forge the source address and bypass the allowlist. It is empty by default for exactly that reason: by default the peer address is judged, and it cannot be forged.

The default value has two sources, don't confuse them:

| Scenario | Allowed by default | Notes |
|---|---|---|
| Unraid template / `compose.yaml` | loopback + private ranges (10/8, 172.16/12, 192.168/16) + link-local + CGNAT/Tailscale (100.64/10) | works out of the box; for `docker run`, copy the template's values |
| The image itself (variable not set) | loopback only | secure default; access over a published port gets `403` |

### Troubleshooting: the UI returns 403

1. In the container logs, look at the `access control: clients …` line — it prints the allowlist actually in effect;
2. Add your network (e.g. `192.168.0.0/16`) or the reverse proxy's address to `ALLOWED_CLIENTS`;
3. When going through a proxy, also set `TRUSTED_PROXY_CIDRS` as needed.

The implementation lives in `docker/entrypoint.sh` (parsing + generation) and `docker/Caddyfile.{lan,edge}` (marker injection). The rules must be placed inside a **`handle` block**: in testing, a bare `respond` was taken over by the later `route`, and a bare `route` in turn lost to `route /healthz` — both forms let external sources **pass silently** (returning 200). `scripts/smoke.sh` therefore uses a client container on another network specifically to assert 403/200, so that this cannot be broken later.

## What both modes do

- **Managed endpoints return 403**: endpoints such as `/api/settings.openDocument` and `/api/settings.openSettingsDocument` that "open a file on the desktop" are meaningless for remote calls and enlarge the attack surface, so they are rejected outright.
- **Inject security response headers**: CSP, `X-Frame-Options: DENY`, `Referrer-Policy`, `X-Content-Type-Options`, etc.
- **Login bootstrap**: the one-time token DSH prints at startup is handed to the first visitor via an internal rewrite, in exchange for a signed session cookie (`dsh-auth-*`). The token never appears in the browser's address bar.

## The container itself

- Runs as uid/gid `1000` (the non-root account inside the image), and at startup adjusts the owner of `/data` and `/workspace` to `1000:1000` before dropping privileges.
- **Does not mount** the docker socket, `/boot`, or any host directory (apart from the two volumes the user explicitly maps).
- The template **does not require** any secrets; model credentials are configured by you in the app UI and stored in `/data`.
- `AUTH_MODE=builtin` (the default) provides the password gate inside the container: the password is used only to exchange for an HMAC gate cookie (which covers both ordinary requests and the WebSocket handshake), and `/healthz` stays unauthenticated; changing the password or deleting `/data/caddy/data/auth-gate-salt` invalidates every issued cookie.
- **When the login cookie goes stale** (an image update, a container rebuild, or another DSH instance on the same host — cookies ignore ports): the container **automatically** routes document requests once through `/renew` (with a short-lived marker, so no loop), replaying the startup token and issuing a new session ✓ — users usually just need to refresh; you can also visit `/renew` manually once, or clear that site's cookies.
- Only `AUTH_MODE=none` hands authentication to the edge (**if you choose it, do not stack the container's own gate on top**, or users are asked for the password twice); any other value (including `caddy-security`, the default of similar images) makes the container **refuse to start**, avoiding the illusion of "looks authenticated, actually weak".
- ⚠️ A password sent over plain HTTP can be eavesdropped on: internet exposure must be fronted by a reverse proxy that provides HTTPS.
- ⚠️ **The template ships with a default password `12345678`** (so that "it can log in right after install"; this is a deliberate convenience trade-off): the default is public, and **until you change it the gate is effectively nonexistent** — anyone who can reach the port can get in. entrypoint prints a `SECURITY:` warning on every startup, and both the README and the template description put "change the password first" as step one; if you do not want the default, leave "访问口令" empty (a random one is generated on first start and printed once).

## Why the container's outer layer relaxes two settings

The template's `Extra Parameters` contain:

```
--security-opt seccomp=unconfined --security-opt systempaths=unconfined
```

This is so that `bubblewrap` in the **container's inner layer** can create namespaces, thereby giving the agent's command execution real isolation. For the trade-off and the controlled experiments, see [unraid-sandbox.md](unraid-sandbox.md).
