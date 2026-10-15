/**
 * dsh-remote-signin — let the DeepSeek **account** sign-in finish in a browser that
 * is not running on the server.
 *
 * Why it exists
 * -------------
 * `@deepseek-ai/dsh-deepseek-account-platform` hands the browser's own origin to
 * the platform as the OAuth `redirect_uri`, and `loginOrigin()` only accepts a
 * loopback HTTP origin with an explicit port (`http://127.0.0.1:<port>`,
 * `http://localhost:<port>`, `http://[::1]:<port>`). Measured against
 * `POST /auth-api/v0/dsh/auth_init` (2026-10-16):
 *
 *   redirect_uri = http://127.0.0.1:47821/oauth/callback  -> {"code":0, "authorize_url": ...}
 *   redirect_uri = https://dsh.meix.top/oauth/callback    -> {"code":50005, "msg":"PAYLOAD_SCHEMA_MISMATCH"}
 *
 * So a browser on the LAN, on Tailscale or on the public internet — where the UI
 * is normally reached — cannot start a sign-in at all: the request is refused
 * before a login page is ever opened. Only a browser that really is on the
 * machine running DSH (or one tunnelled there with `ssh -L`) can sign in.
 *
 * What this plugin does
 * ---------------------
 * It wraps `deepseekAccount.startSignIn` and, **only when the browser's origin is
 * not already loopback**, replaces that origin with a *claimed* loopback origin
 * (`REMOTE_SIGNIN_ORIGIN`, default `http://127.0.0.1:47821`). The claim exists to
 * satisfy the platform's check; nothing listens on it in the browser.
 *
 * The authorization code the platform sends to that address is therefore never
 * delivered by the browser, so it is brought back **out of band**: the browser
 * shows a "can't reach this page" error whose address bar still holds
 * `code` and `state`, and the bridge page this image serves at `/remote-login`
 * replays that URL against this server. Upstream's own `/oauth/callback` route —
 * unchanged, still validating the `state` this process generated, and still the
 * only thing that exchanges the code with the PKCE verifier held in memory —
 * completes the sign-in.
 *
 * What it deliberately does NOT do
 * --------------------------------
 *   * It never relaxes validation. The callback that ends the flow is upstream's
 *     route on this server with its own `state` check; the plugin only chooses
 *     which loopback *string* is registered as the redirect target.
 *   * It never changes the behaviour of a browser that is already on loopback
 *     (the desktop app, or an `ssh -L` tunnel): those origins pass through
 *     untouched, so the upstream path is bit-for-bit the same.
 *   * It never stores or forwards the authorization code itself, and it logs no
 *     code, state or token — only the origin it claimed for.
 *   * It fails soft: a bad `REMOTE_SIGNIN_ORIGIN`, a missing service or an
 *     un-patchable method leaves the process running with upstream behaviour and
 *     one error line in the log.
 *
 * Loaded by the launcher as a `--patch` overlay (docker/remote-signin/patch.yml),
 * so nothing in `$DSH_HOME/profiles/<name>/cordis.patch.yml` — the operator's own
 * layer — has to be edited.
 */

/** Loopback host spellings upstream's `loginOrigin()` accepts. */
const LOOPBACK_HOSTNAMES = new Set(["localhost", "127.0.0.1", "[::1]"]);

/** The claim used when the operator does not set REMOTE_SIGNIN_ORIGIN. */
export const DEFAULT_CLAIM_ORIGIN = "http://127.0.0.1:47821";

/** Marks the wrapper so the startup check can find it through a tracing accessor. */
const WRAPPER = Symbol.for("dsh.remote-signin.wrapper");

/**
 * Normalize a claimed loopback origin.
 *
 * The same shape upstream accepts, and nothing else: plain HTTP, one of the
 * three loopback spellings, an explicit non-zero port, no credentials, path,
 * query or fragment. Kept identical on purpose — a claim upstream would reject
 * is worse than no claim at all, because it turns a clear local error into a
 * platform error.
 *
 * @param value - candidate origin, typically from REMOTE_SIGNIN_ORIGIN.
 * @returns the normalized `http://host:port` origin, or null when unusable.
 */
export function normalizeClaimOrigin(value) {
  if (typeof value !== "string" || value.trim() === "") return null;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol !== "http:") return null;
  if (!LOOPBACK_HOSTNAMES.has(url.hostname)) return null;
  if (!/^[0-9]{1,5}$/.test(url.port)) return null;
  const port = Number(url.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
  if (url.username || url.password || url.pathname !== "/" || url.search || url.hash) return null;
  return `http://${url.hostname}:${port}`;
}

/**
 * Is this origin one a browser can reach on loopback, as upstream defines it?
 * @param value - the origin the UI reported.
 * @returns true when upstream would accept it unchanged.
 */
export function isLoopbackCallbackOrigin(value) {
  return normalizeClaimOrigin(value) !== null;
}

/**
 * Decide which origin to register with the platform for one sign-in attempt.
 *
 * Pass-through is the default and the common case for a tunnel or the desktop
 * app; only a genuinely remote browser is redirected to the claim.
 *
 * @param value - the callback origin reported by the UI.
 * @param claim - the normalized loopback claim from {@link normalizeClaimOrigin}.
 * @returns the origin to hand to the platform.
 */
export function mapCallbackOrigin(value, claim) {
  return isLoopbackCallbackOrigin(value) ? value : claim;
}

/**
 * Wrap `startSignIn` on the live account service.
 *
 * The prototype is the patch point because that is what every resolution path
 * ends at, including the per-access tracing view Cordis hands back from
 * `ctx.deepseekAccount`. Whether the wrapper is really reachable through that
 * accessor is then verified with a marker and reported once — a silent no-op is
 * the one failure mode an operator could not diagnose from the UI, since the
 * symptom (sign-in fails for a remote browser) is exactly what the feature is
 * meant to cure.
 *
 * @param ctx - Cordis context carrying the account service.
 * @param config - optional `{ claimOrigin }` from the patch entry.
 */
export function apply(ctx, config = {}) {
  const configured = config?.claimOrigin ?? process.env.REMOTE_SIGNIN_ORIGIN ?? DEFAULT_CLAIM_ORIGIN;
  const claim = normalizeClaimOrigin(configured);
  if (claim === null) {
    console.error(
      `[remote-signin] REMOTE_SIGNIN_ORIGIN=${JSON.stringify(configured)} is not a loopback http origin with an explicit port` +
        ` (expected e.g. ${DEFAULT_CLAIM_ORIGIN}); remote sign-in stays off`,
    );
    return;
  }

  let service;
  try {
    service = ctx.deepseekAccount;
  } catch (error) {
    service = undefined;
  }
  if (service === undefined || typeof service.startSignIn !== "function") {
    console.error("[remote-signin] the deepseekAccount service is unavailable; remote sign-in stays off");
    return;
  }

  const prototype = Object.getPrototypeOf(service);
  const original = typeof prototype?.startSignIn === "function" ? prototype.startSignIn : service.startSignIn;
  // The profile reloads its patches live, so this plugin can be applied again in the
  // same process; wrapping the wrapper would double every log line without changing
  // behaviour, and this keeps the log honest.
  if (original?.[WRAPPER] === true) {
    console.log(`[remote-signin] already active — loopback claim ${claim}`);
    return;
  }
  const wrapped = function startSignIn(client, callbackOrigin, loginSource) {
    const mapped = mapCallbackOrigin(callbackOrigin, claim);
    if (mapped !== callbackOrigin) {
      // The origin is not a secret; the code, state and tokens that follow are, and
      // none of them is ever logged here.
      console.log(`[remote-signin] claiming ${claim} for browser origin ${JSON.stringify(callbackOrigin)}`);
    }
    return original.call(this, client, mapped, loginSource);
  };
  wrapped[WRAPPER] = true;

  try {
    prototype.startSignIn = wrapped;
  } catch (error) {
    console.error(`[remote-signin] could not patch the account service: ${error?.message ?? error}`);
    return;
  }

  // Identity comparison is deliberately NOT the check here. The Cordis accessor
  // (`ctx.deepseekAccount`) hands out a per-access tracing view over this same
  // prototype: measured 2026-10-16 on 0.2.1-alpha.4, `ctx.deepseekAccount` is not
  // `ctx.get('deepseekAccount')`, and the view carries its *own* `startSignIn` that
  // forwards to the prototype method. So the honest check is that the marker is
  // reachable through the accessor the API controller uses — and the first
  // "claiming" line in this log is what proves the call really lands in the wrapper.
  const reachable = (value) => Boolean(value) && value[WRAPPER] === true;
  let via = "none";
  try {
    const view = ctx.deepseekAccount;
    if (reachable(view?.startSignIn)) via = "accessor";
    else if (reachable(Object.getPrototypeOf(view)?.startSignIn)) via = "accessor prototype";
  } catch (error) {
    via = "unknown";
  }

  if (via === "none") {
    console.error("[remote-signin] INACTIVE — the account service does not resolve the patched startSignIn; remote sign-in stays off");
    return;
  }
  console.log(
    `[remote-signin] active — a remote browser signs in through the loopback claim ${claim}` +
      ` (reached via the ${via}); finish it at /remote-login`,
  );
}

export const name = "dsh-remote-signin";
export const inject = ["deepseekAccount"];
export default { name, inject, apply };
