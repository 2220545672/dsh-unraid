<p align="center"><img src="https://gh-proxy.com/https://raw.githubusercontent.com/2220545672/dsh-unraid/main/templates/img/dsh.png" width="128" alt="DSH for Unraid"></p>

<h1 align="center">DSH for Unraid</h1>

<p align="center">DeepSeek Harness in a container: a coding agent you drive from the browser, with a command sandbox that actually works on Unraid kernels — updated automatically from upstream.</p>

<p align="center">
  <a href="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml"><img src="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml/badge.svg" alt="validate"></a>
  <img src="https://img.shields.io/badge/image-ghcr.io%2F2220545672%2Fdsh-2496ed" alt="image">
  <img src="https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey" alt="platforms">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <a href="https://github.com/2220545672/dsh-unraid/releases"><img src="https://img.shields.io/github/v/release/2220545672/dsh-unraid?label=tracking&color=orange" alt="tracking"></a>
</p>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">中文说明</a></p>

---

## What this is

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (**DSH**) is an open-source coding agent. You talk to it in a browser tab; it reads and edits your project files, runs commands on your server, keeps your session history, and extends through plugins.

This repository packages it for Unraid: a multi-architecture container image, a Community Applications template, and the documentation to go with them.

```
ghcr.io/2220545672/dsh:latest
```

## Features

- **A command sandbox that works out of the box.** Tools run inside `bubblewrap`, and the template ships the two launch options it needs on Unraid. No hunting down `SANDBOX_UNAVAILABLE`.
- **Updated automatically.** A daily check rebuilds, smoke-tests and publishes whenever upstream releases a new version. You just hit update.
- **Multi-arch.** `linux/amd64` and `linux/arm64`, with SBOM and provenance attestations.
- **Tight runtime.** Non-root (uid 1000), no docker socket, no `/boot`, no credentials in the template.
- **Authentication at the edge.** No password login inside the container; pair it with SWAG + Authelia, a VPN, or a trusted LAN.
- **Documented.** Installation, sandbox, migration and troubleshooting guides in [`docs/`](docs/).

## Quick start

### 1. Community Applications (once listed)

Search for **DSH** in the `Apps` tab — the description mentions "DeepSeek Harness", so searching `deepseek` finds it too.

### 2. Unraid `Docker → Add Container` (works today)

Paste the contents of [`templates/dsh.xml`](templates/dsh.xml) into the template editor, or import the file. **Do not remove `Extra Parameters`:**

```
--security-opt seccomp=unconfined --security-opt systempaths=unconfined
```

### 3. Docker Compose

```bash
git clone https://github.com/2220545672/dsh-unraid.git
cd dsh-unraid
DSH_IMAGE=ghcr.io/2220545672/dsh:latest PUBLIC_URL=https://dsh.example.com docker compose up -d
```

### 4. docker run

```bash
docker run -d --name dsh --restart unless-stopped \
  -p 8080:8080 \
  -e TZ=Asia/Shanghai \
  -e PUBLIC_URL=https://dsh.example.com \
  -e ALLOWED_CLIENTS=127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10 \
  -v /mnt/user/appdata/dsh/data:/data \
  -v /mnt/user/appdata/dsh/workspace:/workspace \
  --security-opt seccomp=unconfined \
  --security-opt systempaths=unconfined \
  ghcr.io/2220545672/dsh:latest
```

Then open `http://<your-server>:8080`. **You do not need to copy a token URL out of the logs** — the first visit completes the login automatically.

> The `ALLOWED_CLIENTS` line is not optional when you run the container yourself: without it the container falls back to loopback only and answers `403` to your browser. The Unraid template and `compose.yaml` already ship a permissive default (loopback, private ranges, link-local, CGNAT/Tailscale); see the [configuration table](#configuration).

## Configuration

| Name | Default | Notes |
|---|---|---|
| `8080` (container port) | — | The only port you need to publish, served by the bundled proxy. DSH itself listens on `127.0.0.1:3080` only. |
| `/data` | — | `DSH_HOME`: sessions, credentials, agent home, proxy state. **Must be persistent**, or rebuilding the container loses your sessions. |
| `/workspace` | — | The agent's working directory (`DSH_WORKSPACE`). |
| `ALLOWED_CLIENTS` | `127.0.0.1` | **Who may connect at all.** Comma-separated list; **IPs/CIDRs** are matched against the connecting address, **hostnames** against the `Host` header. Loopback is always allowed, because the container's own healthcheck uses it. The **Unraid template and `compose.yaml` ship a permissive default** (loopback, private ranges, link-local, CGNAT/Tailscale); a bare `docker run` falls back to loopback only, which means `403` until you add your network. |
| `TRUSTED_PROXY_CIDRS` | empty | Optional, only with a reverse proxy in front. Caddy then reads `X-Forwarded-For` **from these peers only**, so `ALLOWED_CLIENTS` sees the real client address. Never list a range untrusted clients can originate from — they could forge the header and bypass the allowlist. |
| `PUBLIC_URL` | empty | Public origin, e.g. `https://dsh.example.com` (scheme + host only, no path). Setting it enables **edge mode**; leaving it empty is **lan mode**. |
| `DSH_TRUSTED_HOSTS` | empty | Extra accepted authorities, comma separated (e.g. `dsh.example.com,192.168.1.10:8080`). Edge mode only. |
| `TZ` | `Asia/Shanghai` | Container time zone. |
| `AUTH_MODE` | `builtin` | **Who guards the UI.** `builtin` serves the container's own password gate (default); `none` delegates authentication to an authenticating proxy or a trusted network. Any other value — including the `caddy-security` that other packaging defaults to — **fails closed** with an explanation, rather than booting wide open while its owner believes a login is in place. |
| `DSH_PASSWORD` | empty | Password for the built-in gate (`DSH_PASSWORD_FILE` works too). Empty means the container generates one on first start and prints it **once** in the log. At least 8 characters, no whitespace. Changing it invalidates every issued login cookie. |

**Volume ownership:** the entrypoint takes ownership as `1000:1000` (the `node` account inside the image). Do **not** change it to `99:100`.

**Choosing a mode**

| Mode | Use when | Set |
|---|---|---|
| **edge** | Something authenticates in front of it: SWAG + Authelia, a VPN, or any HTTPS reverse proxy | `PUBLIC_URL=https://your.domain` |
| **lan** | Only reached from a network you trust | leave `PUBLIC_URL` empty |

Never publish lan mode to the internet. The container validates the host and origin of every request and adds security headers either way; the details are in [docs/security.md](docs/security.md).

## Authentication

The container serves its own password gate and it is **on by default**, because a default install must not be usable by everybody who can reach the port: this app runs commands in the mounted workspace and keeps your model credentials in `/data`.

* **If the page says "dsh web authentication required; reopen the URL printed by dsh web", open `http://<host>:<port>/renew` once.** DSH signs its own session cookie with a secret its process owns, while the browser keeps that cookie across container recreations, image updates, and other DSH instances on the same host — cookies ignore ports, so two instances write the same cookie name. The bootstrap that normally signs you in steps aside whenever *any* `dsh-auth-*` cookie is present, so a stale one leaves the app unreachable; `/renew` replays the launch token and DSH mints a fresh cookie. Clearing the site's cookies for that host works too.
* **Change the default password first.** The Unraid template ships `12345678` so that a fresh install has a working login. That value is public: **until you change it, anybody who can reach the port and knows it can drive the agent** (run commands in the mounted workspace, read the credentials in `/data`). Change 访问口令 / `DSH_PASSWORD` in the container settings; the container logs a warning at every start while the default is in use.
* **The login is user name + password.** The user name defaults to `dsh` and is a template field of its own (访问用户名 / `AUTH_USER`); it must match `[A-Za-z0-9][A-Za-z0-9._-]*` or the container refuses to start. The password comes from `DSH_PASSWORD` (or `DSH_PASSWORD_FILE`); clearing the template field falls back to its `Default` (`12345678`), and passing an explicitly empty `-e DSH_PASSWORD=` from the CLI generates a random one on first start and prints it **once** in the log — `docker logs <container>`, or the Docker tab → the container → Logs.
* **How it works.** The password is asked for once through the browser's ordinary login prompt (HTTP basic auth). That successful check mints a cookie whose value is an HMAC of the password and a per-install salt; the cookie then carries the session for ordinary requests **and for the client's WebSocket** — browsers do not reliably attach cached HTTP credentials to a WebSocket upgrade, which is why the gate is not "basic auth on every request". `/healthz` stays open so the container healthcheck keeps working. Changing the password (or deleting `/data/caddy/data/auth-gate-salt`) invalidates every issued cookie.
* **A password over plain HTTP is not safe on the internet.** The gate protects the application, not the wire: if you expose this beyond your LAN, terminate TLS in a reverse proxy in front. Set `PUBLIC_URL` for that so the container only answers for that authority.
* **Already have SSO?** Set `AUTH_MODE=none` and let the proxy authenticate (SWAG + Authelia, Authentik, ...). `ALLOWED_CLIENTS` stays in force as a second layer. Any other `AUTH_MODE` value fails closed.

### Choosing a shape

Three shapes cover almost everybody. They are mutually exclusive on purpose: **never stack two logins** — if a proxy already authenticates the browser, do not also put the container's gate in front of it (the user would be asked twice).

| Shape | Settings | Pick it when |
|---|---|---|
| **Single box with the built-in gate** (default) | `AUTH_MODE=builtin`, password in `DSH_PASSWORD` (empty = generated and printed once), `ALLOWED_CLIENTS` as shipped | You have no reverse proxy or SSO, and want remote access to work after one install. Put it behind a TLS proxy before exposing it to the internet. |
| **Reverse proxy with SSO** | `AUTH_MODE=none`, `PUBLIC_URL=https://dsh.example.com`, `TRUSTED_PROXY_CIDRS=<your proxy's network>` | You already run SWAG/NPM/Authelia/Authentik (or any authenticating front end) and want 2FA, audit logs and central revocation. `ALLOWED_CLIENTS` stays in force as a second layer. |
| **LAN or tunnel only** | `AUTH_MODE=none` (or `builtin`), `ALLOWED_CLIENTS` narrowed to your own subnets | The port is only reachable from home or through Tailscale / an SSH tunnel, and you accept that anyone who gets there acts as you. |

An unknown `AUTH_MODE` never boots: the container refuses to start and says which values it accepts, so a configuration copied from another image fails closed instead of silently losing a login.

## Updating and version tags

The image follows upstream automatically: a new release is built, smoke-tested and published, tagged as `dsh-<version>`, and announced as a GitHub release (with a version-pinned template for reproducible installs).

| Tag | Meaning |
|---|---|
| `:<version>` (e.g. `:0.2.1-alpha.3`) | Immutable, for pinning |
| `:latest` | Always the newest build (prereleases included) |
| `:alpha` / `:rc` / `:stable` | Follows the matching upstream release channel |

To update on Unraid: **Docker → your container → force update** (or wait for the "apply update" hint). No configuration changes are needed, and everything in `/data` and `/workspace` is preserved.

## Known limitations

**Single-user only.** There is no user database and no second account: whoever reaches the UI acts as the same workspace owner. The container serves one password for that owner by default (see [Authentication](#authentication)); to get real multi-user separation, authenticate in front (reverse proxy, SSO, VPN) and keep it on a trusted network.

**DeepSeek account sign-in needs a loopback browser.** The account flow hands `window.location.origin` to the server, and both the client and the **platform** accept only `http://localhost|127.0.0.1|[::1]:<port>` as the callback. Measured against `https://platform.deepseek.com/auth-api/v0/dsh/auth_init`: the loopback URL returns `code:0`, while LAN, Tailscale and reverse-proxy origins return `50005 PAYLOAD_SCHEMA_MISMATCH`.

Consequences:

* From a LAN, Tailscale or proxied URL the sign-in button always fails ("登录失败 / 操作未完成，请重试"), and retrying cannot help.
* **No image change can lift this.** Patching the check inside the container would only move the rejection one step later, to the platform. The platform exposes just `auth_init`, `auth_exchange` and `auth_cancel` — there is no device-code channel that skips the browser callback.
* **Use an API key** (the same panel offers *Add API key*) — that is what a server deployment should do — **or sign in once through a loopback tunnel**: `ssh -p 1022 -L 3081:127.0.0.1:3081 root@<server>`, open `http://127.0.0.1:3081`, sign in. The grant is stored **server-side** (`/data/dsh` credentials), so a single tunnel sign-in keeps you signed in when you later browse from LAN or Tailscale.

**Upstream is a prerelease.** `@deepseek-ai/dsh` currently publishes only `alpha`/`rc` builds, and this image tracks the newest of them (see [Updating and version tags](#updating-and-version-tags)).

**Image size and pull speed.** ~0.74 GB unpacked (0.2.1-alpha.3 started at 1.09 GB; the dependency tree is pruned at build time), pulling anonymously from GHCR measured around 1 MB/s on a China line. See [Testing and verification](#testing-and-verification).

**What the size work does and does not touch.** The pruning removes build-time files only — TypeScript sources and declarations, source maps, documentation and test fixtures (349 MB on 0.2.1-alpha.3, verified byte-identical on the plugin bundle a browser loads). No package is removed and every functional file survives, including the LibreOffice wasm assets behind document preview (146 MB) and every licence file.

## FAQ

**DeepSeek account sign-in fails with "登录失败 / 操作未完成，请重试" (or "Login failed, please retry")**

That is an upstream limitation, not this image. The account flow passes `window.location.origin` to the server, and the platform module only accepts a **loopback** callback:

```js
// @deepseek-ai/dsh-deepseek-account-platform
const explicitPort = /^http:\/\/(?:localhost|127\.0\.0\.1|\[::1\]):([0-9]+)\/?$/i.exec(value)?.[1];
// "remote domains and path-based proxies are unsupported"
```

So the browser must reach DSH at `http://127.0.0.1:<port>` (or `localhost` / `[::1]`) for account sign-in to start; any LAN, Tailscale or reverse-proxy origin is rejected before a request is even made, and retrying cannot help.

**No image change can lift this.** Submitting the same `redirect_uri` straight to the platform's `auth_init` shows the platform enforces it too: `http://127.0.0.1:3081/oauth/callback` returns `code:0`, while LAN, Tailscale and reverse-proxy origins all return `code:50005 PAYLOAD_SCHEMA_MISMATCH`. Patching the check in the image would only move the rejection one step later. The platform exposes just `auth_init`, `auth_exchange` and `auth_cancel` — there is no device-code channel that avoids the browser callback.

Two ways forward:

* **Use an API key** — the same panel offers *Add API key*, and that is what a server deployment should use.
* **Tunnel the UI to loopback** if you want the account flow: `ssh -L 3081:127.0.0.1:3081 root@<server>`, then open `http://127.0.0.1:3081`. The browser origin is then loopback, which is exactly what the check wants.

**The UI does not load, or spins forever.**
Check `docker logs dsh | head -30` first — the entrypoint prints the mode (edge/lan), the upstream version and the startup result. Then make sure `PUBLIC_URL` matches the address you actually open (scheme + host, no trailing path).

**A tool reports `SANDBOX_UNAVAILABLE`.**
The two `--security-opt` values in `Extra Parameters` were removed. Restore them — the container's outer sandbox is relaxed slightly so the agent's inner sandbox can work at all; see [docs/unraid-sandbox.md](docs/unraid-sandbox.md) if you want the full reasoning.

**Port 8080 is taken.**
Change the host port mapping in the template. Keep the container port at 8080.

**I updated but nothing changed.**
Unraid only recreates a container when the image digest changes. Use **force update**, then confirm the digest with `docker inspect`.

**How do I put it behind a reverse proxy?**
Set `PUBLIC_URL=https://your.domain` and point the proxy at `container-name:8080`. If your proxy rewrites the host header (SWAG does), nothing else is needed; if it presents a different authority, list it in `DSH_TRUSTED_HOSTS`.

**Where is my data, and how do I back it up?**
Sessions and credentials live in `/data` (default `appdata/dsh/data`), projects in `/workspace` (default `appdata/dsh/workspace`). Back up those two directories; updating or recreating the container leaves them untouched.

**Why does the container run as uid 1000 instead of Unraid's usual `99:100`?**
The image runs as a fixed non-root account and takes ownership of its volumes at startup, so file permissions behave the same on every host.

**Is arm64 supported?**
Yes, CI builds and publishes `linux/arm64` — but it has not been exercised on real ARM hardware yet. Issues welcome.

**Is upstream still prerelease?**
Yes. `:latest` follows upstream's prereleases; pin a specific `:<version>` tag if you prefer stability.

## Testing and verification

Every release is built, started and smoke-tested in CI before it is published, and the repository and template are checked automatically as well — a failing check means nothing gets published.

| Check | Coverage |
|---|---|
| Image smoke test (every release) | lan mode: `/healthz` = ok, `/` returns 303 with a `dsh-auth*` cookie, cross-site `/api` refused with 403, managed endpoints refused with 403, both proxy configurations validate, `bwrap` usable inside the container. Edge mode: the container starts, foreign origins are refused with 403, the declared origin reaches DSH. |
| Real Unraid host | Unraid 7.3.2 / kernel `6.18.38-Unraid`: edge mode starts, `/healthz` = ok, `/` returns **303** with a cookie, and `bwrap … echo SANDBOX_OK` prints **SANDBOX_OK** inside the container. |
| Artifacts | Multi-arch index (amd64 + arm64) plus SBOM/provenance attestations; anonymous `docker pull` verified. |
| Template and repository | Community Applications field requirements, `ca_profile.xml`, volume/`Config` path consistency and icon reproducibility are asserted by script. |

## Documentation

| Document | Contents |
|---|---|
| [docs/unraid-sandbox.md](docs/unraid-sandbox.md) | Why Unraid needs the sandbox setup it does, with the experiments behind it |
| [docs/security.md](docs/security.md) | How the container validates hosts and origins, and what each mode does |
| [docs/migrate-from-another-image.md](docs/migrate-from-another-image.md) | Moving over from another DSH image, with minimal downtime |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Building, testing, releasing and the template/icon workflow |
| [docs/ca-submission.md](docs/ca-submission.md) · [docs/ca-pitfalls.md](docs/ca-pitfalls.md) | Community Applications submission, and the pitfalls of that ecosystem |

## Support

- **Bugs and feature requests:** [GitHub Issues](https://github.com/2220545672/dsh-unraid/issues).
- Please include: the first 30 lines of `docker logs <container>`, your Unraid version, your kernel version (`uname -r`), and how `PUBLIC_URL` is set (domain redacted).
- Problems inside DSH itself (models, plugins, UI behaviour) belong upstream at [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness).

## License and trademarks

- This repository is **MIT** licensed, see [LICENSE](LICENSE). DeepSeek Harness itself is published by DeepSeek under MIT; this repository only packages it.
- The icon is original artwork combining the official DSH mark with the official Unraid mark; sources and the trademark note are in [templates/img/src/README.md](templates/img/src/README.md).
- This is a **community packaging**. It is not affiliated with, endorsed by, or authorised by DeepSeek or Lime Technology. Naming follows the DSH brand guidance: the project is called **DSH**, and "DeepSeek Harness" appears only in descriptive text.
