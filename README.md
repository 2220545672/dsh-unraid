<p align="center"><img src="https://gh-proxy.com/https://raw.githubusercontent.com/2220545672/dsh-unraid/main/templates/img/dsh.png" width="128" alt="DSH for Unraid"></p>

<h1 align="center">DSH for Unraid</h1>

<p align="center"><a href="https://github.com/deepseek-ai/deepseek-harness">DeepSeek Harness</a> — a coding agent you drive from the browser — running on your Unraid server. One container, a command sandbox that works on Unraid kernels, updated automatically from upstream.</p>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">中文说明</a></p>

<p align="center">
  <a href="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml"><img src="https://github.com/2220545672/dsh-unraid/actions/workflows/validate.yml/badge.svg" alt="validate"></a>
  <a href="https://github.com/2220545672/dsh-unraid/releases"><img src="https://img.shields.io/github/v/release/2220545672/dsh-unraid?label=tracking&color=orange" alt="tracking"></a>
  <img src="https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-lightgrey" alt="platforms">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>

---

> **Developer preview.** DeepSeek Harness is in _developer preview_ and iterating rapidly. **THERE WILL BE COMPATIBILITY-BREAKING CHANGES.** — quoted from the [upstream project](https://github.com/deepseek-ai/deepseek-harness#developer-preview). This image tracks upstream releases automatically, so pin a [version tag](#update) if you would rather move on your own schedule.

## Install

**On Unraid (recommended)**

1. Open the **Apps** tab and search for **DSH** — it is listed in Community Applications. *Feed not refreshed yet?* Use **Docker → Add Container** and paste [`templates/dsh.xml`](templates/dsh.xml) into the template editor.
2. Leave **Extra Parameters** as it is. The two `--security-opt` values are what let the agent's sandbox work on Unraid, and `--restart=unless-stopped` brings it back after a Docker restart.
3. Apply, then open **`http://<your-server>:8080`**.

**With Docker or Compose**

```bash
docker run -d --name dsh --restart unless-stopped -p 8080:8080 \
  -e ALLOWED_CLIENTS=127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10 \
  -v /mnt/user/appdata/dsh/data:/data \
  -v /mnt/user/appdata/dsh/workspace:/workspace \
  --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
  ghcr.io/2220545672/dsh:latest
```

`ALLOWED_CLIENTS` is not optional when you write the command yourself: without it the container accepts loopback only and answers `403` to your browser. Compose users: [`compose.yaml`](compose.yaml) already ships it.

## First five minutes

1. **Open the UI.** The first visit signs you in — there is no token to copy out of the logs.
2. **Change the password.** The template ships `12345678`, which is public knowledge. It is the **Password** field (`DSH_PASSWORD`). (Cleared, the container generates one and prints it once: `docker logs <container>`.) User name defaults to `dsh`.
3. **Add a DeepSeek API key** — *Add API key* in the same panel. A DeepSeek **account** also works from any browser: the login tab ends on a dead `127.0.0.1` page, and `/remote-login` finishes it — see [docs/remote-signin.md](docs/remote-signin.md).
4. **Point it at your project.** The agent works in `/workspace` (default `appdata/dsh/workspace`).

## How it is put together

One container, two processes, one port:

```text
browser ──▶ :8080  Caddy (bundled)  ──▶ 127.0.0.1:3080  DSH
                     ├─ optional password gate (on by default)
                     ├─ allowlist: ALLOWED_CLIENTS
                     ├─ security headers, host/origin checks
                     └─ /healthz for the container healthcheck
```

- **The reverse proxy is already in the image.** Caddy serves the port you publish and forwards to DSH, which listens on loopback only — so the published port is the single way in, and the proxy is the layer that adds the security headers, refuses cross-site calls and blocks the endpoints that make no sense remotely. There is nothing extra to install or configure.
- **Authentication is optional, and it is one switch.** `AUTH_MODE=builtin` (the default) asks for a password once through the browser's ordinary login prompt, then keeps you signed in with a cookie that also covers the WebSocket; `AUTH_MODE=none` hands that job to whatever sits in front (SWAG + Authelia, a VPN, a trusted LAN). Any other value refuses to start instead of booting unprotected — and never stack two logins. The container's own healthcheck stays open either way.
- **The allowlist lives at the same layer.** `ALLOWED_CLIENTS` decides who may reach the container at all; loopback is always allowed, which is what keeps the healthcheck working.
- **It runs unprivileged.** uid 1000, no docker socket, no host directories beyond the two volumes you map. Credentials are stored in `/data` — the reason that volume must be persistent.
- **A password over plain HTTP is not safe on the internet.** The gate protects the app, not the wire: terminate TLS in whatever you put in front before exposing this.

## Update

Unraid: **Docker → your container → force update** (or click the "apply update" hint). Everything in `/data` and `/workspace` survives.

| Tag | Meaning |
|---|---|
| `:latest` | Newest build, upstream prereleases included |
| `:0.2.1-alpha.3` | Pin an exact version |
| `:alpha` · `:rc` · `:stable` | Follow one upstream channel |

An hourly job checks upstream, rebuilds and smoke-tests the image, and publishes only when the checks pass. Upstream currently ships alpha/rc builds, so `:latest` moves often — pin a version tag if you would rather update on your own schedule.

## Problems

| Symptom | Fix |
|---|---|
| “dsh web authentication required; reopen the URL printed by dsh web” | **Just reload the page.** The browser is holding a session cookie this DSH no longer accepts (it happens after an image update, a container recreation, or another DSH on the same host — cookies ignore ports). The container notices and renews the session by itself; opening `http://<host>:<port>/renew` manually, or clearing that site's cookies, does the same thing. |
| A tool reports `SANDBOX_UNAVAILABLE` | The two `--security-opt` values were removed from **Extra Parameters**. Put them back. |
| The browser gets `403` | Your address is not in `ALLOWED_CLIENTS`; a plain `docker run` allows loopback only. |
| “登录失败 / 操作未完成” when signing in with a DeepSeek account | Upstream only accepts a **loopback** browser origin, so the login tab is redirected to `127.0.0.1` and dies there. **That is the step the bridge finishes:** copy the dead page's address, paste it at `/remote-login` — within ~10 minutes and in the same container (an update or a container recreation discards the attempt). The bridge page reports what the server answered, so an expired code says so instead of leaving you on an empty 404. If the page says the overlay is off, set `REMOTE_SIGNIN=on` (it is the default). Prefer no paste? Tunnel once and use a loopback origin: `ssh -L 3081:127.0.0.1:<published port> root@<server>`, open `http://127.0.0.1:3081`. |
| Updated, but nothing changed | Unraid recreates a container only when the image digest changes — use **force update**. |
| Page never finishes loading | `PUBLIC_URL` must match the address you actually open (scheme + host, no path). `docker logs <container> \| head -30` prints the mode it chose. |

## Settings you may need

| Setting | Default | What it does |
|---|---|---|
| `8080` | — | The only port to publish. DSH listens on `127.0.0.1:3080` inside; a bundled proxy serves `:8080`. |
| `/data` · `/workspace` | — | Sessions, credentials and the agent home · your projects. **Both must be persistent.** |
| `ALLOWED_CLIENTS` | loopback only | Who may connect at all: IPs/CIDRs (and hostnames, matched against `Host`). |
| `PUBLIC_URL` | empty | Public origin (`https://dsh.example.com`) when a reverse proxy is in front; leave empty for LAN/Tailscale only. |
| `AUTH_MODE` | `builtin` | `builtin` = password gate inside the container; `none` = your proxy authenticates. Any other value refuses to start. |
| `REMOTE_SIGNIN` | `on` | DeepSeek **account** sign-in from a remote browser, finished at `/remote-login`. `off` = upstream's loopback-only behaviour. |
| `DSH_PASSWORD` | `12345678` in the template | Password for the built-in gate (or `DSH_PASSWORD_FILE`). |
| `TZ` | `Asia/Shanghai` | Container time zone. |

Already running SSO (SWAG + Authelia, Authentik, …)? Set `AUTH_MODE=none` and `PUBLIC_URL`, and **do not stack a second login** — see [docs/security.md](docs/security.md).

Volumes are taken over as `1000:1000`. Leave that alone — it is not Unraid's usual `99:100`.

## Learn more

| Document | Contents |
|---|---|
| [docs/security.md](docs/security.md) | Password gate, host/origin checks, `ALLOWED_CLIENTS`, 403 troubleshooting |
| [docs/remote-signin.md](docs/remote-signin.md) | Signing in with a DeepSeek **account** from the LAN, Tailscale or behind a proxy |
| [docs/unraid-sandbox.md](docs/unraid-sandbox.md) | Why Unraid needs those two `--security-opt` values |
| [docs/migrate-from-another-image.md](docs/migrate-from-another-image.md) | Moving over from another DSH image |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Building, testing, releasing, template workflow |
| [docs/ca-submission.md](docs/ca-submission.md) | Community Applications submission notes |

**Known limits.** Single-user by design: there is no account database, so everyone who reaches the UI acts as the same owner. DeepSeek **account** sign-in from a remote browser costs one paste step (`/remote-login`); an API key skips it entirely. Upstream is in developer preview, so breaking changes are expected — see the notice at the top. About 0.9 GB on disk.

## Support

- **Unraid forum thread:** [DSH — DeepSeek Harness, AI coding agent in your browser](https://forums.unraid.net/topic/200908-support-dsh-deepseek-harness-ai-coding-agent-in-your-browser/)
- **Bugs and requests:** [GitHub Issues](https://github.com/2220545672/dsh-unraid/issues) — please include `docker logs <container> | head -30`, your Unraid and kernel version (`uname -r`), and how `PUBLIC_URL` is set.
- **Problems inside DSH itself** (models, plugins, UI): [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness).

## License

MIT — see [LICENSE](LICENSE). DeepSeek Harness itself is MIT, published by DeepSeek; this repository only packages it.

Community packaging: not affiliated with, endorsed by or authorised by DeepSeek or Lime Technology. The icon combines the official DSH mark with the official Unraid mark ([sources and trademark note](templates/img/src/README.md)).
