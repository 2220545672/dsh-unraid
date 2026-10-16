**English** · [中文](remote-signin.zh-CN.md)

# Signing in with a DeepSeek account from a remote browser

> How the container lets `Sign in` work when the UI is reached over the LAN, over
> Tailscale or through a reverse proxy — where upstream's sign-in cannot work at all.
> Set `REMOTE_SIGNIN=off` to get upstream's behaviour back.

## What you would see without this

You open the UI from another machine, press **Sign in** with a DeepSeek account, and no
login page appears — the dialog fails instead, with the account panel's own wording
("Could not complete the operation. Try again.", or its network-problem variant). The
same click works from a browser on this machine, or through an `ssh -L` tunnel, and an
API key is unaffected. With `REMOTE_SIGNIN=on` the login page opens as usual; the only
step it adds is pasting the dead `127.0.0.1` address into a panel that appears in the
page by itself.

## The problem, measured

Upstream gives the platform the **browser's own origin** as the OAuth `redirect_uri`,
and `@deepseek-ai/dsh-deepseek-account-platform` only accepts a loopback HTTP origin
with an explicit port. Anything else is refused before a login page is ever opened.
Measured against the real platform on 2026-10-16 (`POST /auth-api/v0/dsh/auth_init`):

| `redirect_uri` | platform answer |
|---|---|
| `http://127.0.0.1:47821/oauth/callback` | `{"code":0, … "authorize_url": …}`, `expires_in: 600` |
| `https://dsh.meix.top/oauth/callback` | `{"code":50005,"msg":"PAYLOAD_SCHEMA_MISMATCH"}` |

So a DeepSeek **account** sign-in only ever worked from a browser running on the
machine that runs DSH — or from a browser tunnelled there with `ssh -L`. On an Unraid
box there is no browser to run, and a tunnel is a lot of ceremony for one login.
(An **API key** has never had this restriction; it is set in the UI and works from
anywhere.)

## Why the obvious alternatives were not used

| Idea | Why not |
|---|---|
| Send the platform a public `redirect_uri` | Refused: the platform answers `50005` for every non-loopback value. Not configurable, and not something the image can talk it out of. |
| Log in from a browser inside the container (headless Chrome, VNC) | Works only for the operator who can reach that browser, and drags an entire browser stack into a 0.9 GB image to do it. |
| Patch the web UI so it asks the operator for a loopback port it can forward | The browser still cannot *reach* that port; a client-side forwarder (an SSH tunnel, a proxy, an extension) is exactly the manual step this container is trying to remove. |
| Keep telling people to use `ssh -L` | It works, and it is still documented below — but it needs an SSH client on the client machine, the port DSH is published on, and a browser tab pointed at `http://127.0.0.1:<port>`. |

## How it works

The platform's check is about the **string** it is given, and the browser is the only
thing that has to reach the address in it. Splitting those two facts is the whole
trick:

```
1.  browser (https://dsh.meix.top)          You click "Sign in".
        │
        │  account/startSignIn, callbackOrigin = "https://dsh.meix.top"
        ▼
2.  DSH host + the plugin                    The origin is not loopback, so it is
        │                                    replaced by the claimed loopback origin
        │  auth_init(redirect_uri = "http://127.0.0.1:47821/oauth/callback")
        ▼
3.  platform.deepseek.com                    Accepts the claim, returns authorize_url.
        │
        │  browser opens the login page, you log in
        ▼
4.  browser                                 The platform redirects it to
        │                                    http://127.0.0.1:47821/oauth/callback?code=…
        ▼                                    Nothing listens there → the browser shows
     "can't reach this page"                 its own error page — with the code and
        │                                    state still in the address bar.
        │  you paste that address into the panel the page now shows
        ▼
5.  DSH host, the panel → /oauth/callback      Upstream's own callback route: it
        │                                       checks the one-time `state` this
        │                                       process generated, exchanges the code
        ▼                                       with the PKCE verifier it kept in
6.  sign-in dialog turns green                  memory, stores the credential.
```

Two halves, both in the [plugin](https://github.com/2220545672/dsh-remote-signin) that
this image installs and pins:

* **The claim** — `src/index.js` wraps `deepseekAccount.startSignIn` and replaces a
  non-loopback browser origin with `REMOTE_SIGNIN_ORIGIN` (default
  `http://127.0.0.1:47821`). A browser already on loopback passes through untouched, so
  the desktop app and an `ssh -L` session keep upstream behaviour exactly.
* **The way back** — `assets/inpage.js` is injected into the DSH document and puts the
  paste box into the page while an attempt waits. It takes only `code` and `state` out of
  the pasted address and sends them to `/oauth/callback` **on the origin you are already
  using** — nowhere else, so the panel cannot act as a redirector. There is no second
  page: the panel is the only way the code comes back.

The image itself only decides *whether* and *with which claim* the plugin loads
(`REMOTE_SIGNIN`, `REMOTE_SIGNIN_ORIGIN`, and the launcher `--patch` the entrypoint
passes). The plugin's code, its panel and its page are maintained in its own repository.

## What it deliberately does not do

* **It does not relax any validation.** The callback that completes the sign-in is
  upstream's route on this server, with upstream's one-time `state` check and
  upstream's PKCE verifier. The overlay only chooses which loopback *string* is
  registered as the redirect target.
* **It does not touch a browser that is already on loopback.** There is no behaviour
  change to test or to fear for the tunnel/desktop case.
* **It does not store or log the code, the state or the token.** The only line it
  writes is the origin it claimed for, once per attempt.
* **It does not open a port.** The claim is a string; nothing ever listens on
  `127.0.0.1:47821`, on the server or on your machine.
* **It never becomes the reason a container will not start.** A missing overlay, a
  syntax error in it, or a future upstream rename of the account service leaves the
  container running with upstream behaviour and one line in the log.

## Security notes

* `/remote-signin/inpage.js` sits behind the same gate as the rest of the UI (`AUTH_MODE=builtin`
  or whatever authenticates in front). It has to: it hands a credential-bearing URL to
  the server.
* The address you paste contains an authorization **code**. It is single-use, bound to
  this attempt's PKCE verifier, and expires with the attempt (10 minutes upstream).
  The page posts it to this origin only — it never echoes it back into the DOM, and it
  sets `Referrer-Policy: no-referrer` so the code cannot leak through a referrer.
* `/oauth/callback` exists **only while a sign-in attempt is waiting**; with no attempt
  in flight that path answers `404` (asserted in `scripts/smoke.sh`). The bridge page
  alone therefore completes nothing.
* The claimed port is chosen to be unlikely to be in use on an operator's machine
  (`47821`). That matters: if your own computer happened to run something on that
  port, the browser would hand it the code instead of showing the error page. Point
  `REMOTE_SIGNIN_ORIGIN` somewhere else if that worries you — any free-looking port
  works, and changing it costs nothing.

## Using it

1. Press **Sign in** with a DeepSeek account in the DSH UI. The login page opens in a new
   tab; finish it there.
2. That tab then lands on a `127.0.0.1` "can't reach this page" error. **That is the
   expected step.** Select its address bar, copy the whole address.
3. Back in the DSH tab, a panel has appeared by itself in the bottom-right corner — the
   plugin puts it there as soon as an attempt starts waiting. Paste the address, press
   **完成登录 / Finish sign-in**. The panel sends the code and tells you what the server
   answered: signed in, expired, or "that address is not the callback of a waiting
   sign-in".
4. The sign-in dialog in that tab switches to signed in, and the login tab closes itself.

Nothing to jump to and nothing to remember: the panel is the flow, and it is the only way
the code comes back. If it does not appear, the plugin is not loaded — `docker logs
<container> | grep remote-signin` says why — and `REMOTE_SIGNIN=off` is the explicit way
back to upstream's loopback-only behaviour (an API key, or an `ssh -L` tunnel).

Do this **within about ten minutes and against the same container**: the code belongs to
that attempt, it expires with it, and recreating the container (an update, a settings
change) discards it. Nothing breaks if that happens — start the sign-in again.

`docker logs <container> | head -30` prints where the standalone page is, and the plugin
names the claim and its own version when it loads:

```
[entrypoint] remote sign-in: on — a remote browser finishes the sign-in in the DSH page:
             when the login tab lands on the dead http://127.0.0.1:47821 page, a panel
             appears there to paste its address into
[remote-signin] active — v0.2.0, claim http://127.0.0.1:47821, panel at
             /remote-signin/inpage.js
```

(The plugin's own `active` line is printed by DSH and is the one to read when
something looks wrong: it names the claim and the version the image loaded.)

### The seamless alternative (no paste)

If you would rather not paste anything, browse the UI over a loopback origin of your
own — then the whole flow is upstream's, with no claim and no panel involved:

```bash
ssh -N -L 3081:127.0.0.1:3080 root@<server>     # <published port> is what you mapped 8080 to
```

…then open `http://127.0.0.1:3081` instead of the LAN address and sign in there. The
credential is stored server-side, so this is a one-time step. Both routes end in the
same place; the panel exists for the times when the tunnel is not at hand.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `REMOTE_SIGNIN` | `on` | `on` loads the [plugin](https://github.com/2220545672/dsh-remote-signin), which claims the loopback origin and puts the paste panel into the page; `off` is upstream's loopback-only behaviour. Any other value refuses to start. |
| `REMOTE_SIGNIN_ORIGIN` | `http://127.0.0.1:47821` | The loopback origin claimed with the platform. Must be `http://` + one of `127.0.0.1` / `localhost` / `[::1]` + an explicit port; nothing may listen there. |

The plugin's version is pinned by the `REMOTE_SIGNIN_VERSION` build argument in the
[Dockerfile](../Dockerfile) (`v0.1.1` today) — an image gets the version it was built and
tested with, and the plugin's own CI is what validates it.

## Troubleshooting

| Symptom | What it means |
|---|---|
| The panel never appears | The plugin is not loaded: `docker logs <container> \| grep remote-signin` says why (`off`, a missing package, or `INACTIVE`). There is no fallback page — the plugin has to load for the panel to exist. |
| The dialog says *waiting for browser* forever | Expected until you paste into the panel; it expires after 10 minutes. |
| The panel says the address is not a callback address | You copied the wrong tab or a truncated address: it must contain `code=` **and** `state=`, and look like `http://127.0.0.1:<port>/oauth/callback?…`. |
| The panel says **no sign-in is waiting** (`404`) | The attempt is gone, and the panel reports the server's own answer rather than dead-ending you on an empty error page. Two causes, both common: it expired (~10 minutes), or it belonged to a **different DSH instance** — recreating or upgrading the container discards it, and a tab left open from the previous instance still *looks* like it is waiting. Start the sign-in again in the tab you are actually using. |
| The bridge page says the state does not match (`400`) | The address came from a different attempt, or the code was already consumed. Press **Sign in** again. |
| The login tab shows a DeepSeek error instead of a login form | The overlay did not load. `docker logs <container> \| grep remote-signin` says why (`off`, an unreadable overlay, or `INACTIVE`). |
| You want the old behaviour | `REMOTE_SIGNIN=off`, then recreate the container. |

## Where the pieces live

| Path (in the image) | Where it is maintained | Role |
|---|---|---|
| `/app/node_modules/dsh-remote-signin/src/index.js` | [dsh-remote-signin](https://github.com/2220545672/dsh-remote-signin) → `src/index.js` | The claim, the asset routes and the panel injection. |
| `/app/node_modules/dsh-remote-signin/assets/inpage.js` | same repository → `assets/inpage.js` | The panel that appears in the DSH page — the only way the code comes back. |
| `/app/node_modules/dsh-remote-signin/cordis.patch.yml` | same repository → `cordis.patch.yml` | The launcher patch entry the entrypoint passes with `--patch`. |
| `/usr/local/bin/entrypoint.sh` | this repository | Decides whether to load the plugin, validates `REMOTE_SIGNIN_ORIGIN`, and names the standalone page in the log. |
| `/etc/caddy/Caddyfile.{edge,lan}` | this repository | No route of its own for the plugin: `/remote-signin/inpage.js` is proxied like any other path, behind the same gate as the UI. |

The image pins a **tag** of the plugin repository (`REMOTE_SIGNIN_VERSION`, `v0.1.1`
today): the plugin's CI validates it, and an image gets the version it was built with.
Upstream is in developer preview — if `deepseekAccount.startSignIn` or the platform's
callback contract changes, the plugin stops applying itself (and says so) rather than
breaking the container; the paste flow then simply stops being offered, and
`REMOTE_SIGNIN=off` is the explicit way to go back to upstream behaviour.
