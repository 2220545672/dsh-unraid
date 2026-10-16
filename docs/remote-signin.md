**English** · [中文](remote-signin.zh-CN.md)

# Signing in with a DeepSeek account from a remote browser

> How the container lets `Sign in` work when the UI is reached over the LAN, over
> Tailscale or through a reverse proxy — where upstream's sign-in cannot work at all.
> Set `REMOTE_SIGNIN=off` to get upstream's behaviour back.

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
2.  DSH host + REMOTE_SIGNIN overlay         The origin is not loopback, so it is
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
        │  you copy that address into /remote-login
        ▼
5.  DSH host, /remote-login → /oauth/callback   Upstream's own callback route: it
        │                                       checks the one-time `state` this
        │                                       process generated, exchanges the code
        ▼                                       with the PKCE verifier it kept in
6.  sign-in dialog turns green                  memory, stores the credential.
```

Two halves, both in the image:

* **The claim** — `docker/remote-signin/dsh-remote-signin.mjs`, a launcher patch
  overlay (`--patch`, added by the entrypoint only while `REMOTE_SIGNIN=on`). It wraps
  `deepseekAccount.startSignIn` and replaces a non-loopback browser origin with
  `REMOTE_SIGNIN_ORIGIN` (default `http://127.0.0.1:47821`). A browser already on
  loopback passes through untouched, so the desktop app and an `ssh -L` session keep
  upstream behaviour exactly.
* **The bridge** — `docker/remote-signin/bridge.html`, served by the bundled Caddy at
  `/remote-login`. It takes the address you paste, keeps only `code` and `state`, and
  navigates to `/oauth/callback` **on the origin you are already using**. Nothing is
  sent anywhere else, and the page cannot act as a redirector.

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

* `/remote-login` sits behind the same gate as the rest of the UI (`AUTH_MODE=builtin`
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

1. Press **Sign in** with a DeepSeek account in the DSH UI. The login page opens in a
   new tab; finish it there. (Nothing jumps to the bridge for you: the tab that is now
   waiting stays waiting until you do step 3.)
2. That tab then lands on a `127.0.0.1` "can't reach this page" error. **That is the
   expected step.** Select its address bar, copy the whole address.
3. Open **`/remote-login`** on the same address you use for the UI
   (`https://dsh.meix.top/remote-login`, `http://192.168.3.2:8080/remote-login`, …),
   paste the address, press **Continue**. The page sends the code and then tells you
   what the server answered — signed in, expired, or "that address is not the callback
   of a waiting sign-in" — instead of navigating you into a bare error page.
4. The dialog in the original tab switches to signed in, and the login tab closes
   itself.

Do this **within about ten minutes and against the same container**: the code belongs
to that attempt, it expires with it, and recreating the container (an update, a settings
change) discards it. Nothing breaks if that happens — start the sign-in again.

`docker logs <container> | head -30` prints the bridge address, and one line from the
overlay when it loaded:

```
[entrypoint] remote sign-in: on — a remote browser finishes the sign-in at
             https://dsh.example.com/remote-login, by pasting the address of the dead
             http://127.0.0.1:47821 page there
[remote-signin] active — a remote browser signs in through the loopback claim
             http://127.0.0.1:47821 (reached via the accessor); finish it at /remote-login
```

(Without `PUBLIC_URL` the entrypoint cannot know which host port you published, so it
names the path and your own port instead of guessing.)

### The seamless alternative (no paste)

If you would rather not paste anything, browse the UI over a loopback origin of your
own — then the whole flow is upstream's, with no bridge involved:

```bash
ssh -N -L 3081:127.0.0.1:3080 root@<server>     # <published port> is what you mapped 8080 to
```

…then open `http://127.0.0.1:3081` instead of the LAN address and sign in there. The
credential is stored server-side, so this is a one-time step. Both routes end in the
same place; the bridge exists for the times when the tunnel is not at hand.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `REMOTE_SIGNIN` | `on` | `on` loads the overlay and serves `/remote-login`; `off` is upstream's loopback-only behaviour. Any other value refuses to start. |
| `REMOTE_SIGNIN_ORIGIN` | `http://127.0.0.1:47821` | The loopback origin claimed with the platform. Must be `http://` + one of `127.0.0.1` / `localhost` / `[::1]` + an explicit port; nothing may listen there. |

## Troubleshooting

| Symptom | What it means |
|---|---|
| The dialog says *waiting for browser* forever | Expected until you paste the address in step 3; it expires after 10 minutes. There is no jump to `/remote-login`: open it yourself (it is in the startup log). |
| The bridge page says the address is not a callback address | You copied the wrong tab or a truncated address: it must contain `code=` **and** `state=`, and look like `http://127.0.0.1:<port>/oauth/callback?…`. |
| The bridge page says **no sign-in is waiting** (`404`) | The attempt is gone, and the page reports the server's own answer rather than dead-ending you on an empty error page. Two causes, both common: it expired (~10 minutes), or it belonged to a **different DSH instance** — recreating or upgrading the container discards it, and a tab left open from the previous instance still *looks* like it is waiting. Start the sign-in again in the tab you are actually using. |
| The bridge page says the state does not match (`400`) | The address came from a different attempt, or the code was already consumed. Press **Sign in** again. |
| The login tab shows a DeepSeek error instead of a login form | The overlay did not load. `docker logs <container> \| grep remote-signin` says why (`off`, an unreadable overlay, or `INACTIVE`). |
| You want the old behaviour | `REMOTE_SIGNIN=off`, then recreate the container. |

## Where the pieces live

| Path (in the image) | Repository file | Role |
|---|---|---|
| `/etc/dsh/remote-signin/dsh-remote-signin.mjs` | `docker/remote-signin/dsh-remote-signin.mjs` | The overlay: claims the loopback origin. |
| `/etc/dsh/remote-signin/patch.yml` | `docker/remote-signin/patch.yml` | The launcher patch entry that loads it. |
| `/etc/caddy/bridge/remote-login.html` | `docker/remote-signin/bridge.html` | The page served at `/remote-login`. |
| `/etc/caddy/Caddyfile.{edge,lan}` | `docker/Caddyfile.{edge,lan}` | The route that serves it, behind the same gate as the UI. |

Upstream is in developer preview: if `deepseekAccount.startSignIn` or the platform's
callback contract changes, the overlay stops applying itself (and says so) rather than
breaking the container — the paste flow then simply stops being offered.
