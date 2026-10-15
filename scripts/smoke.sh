#!/usr/bin/env bash
#
# Post-build smoke test for one already-built image. Runs on the CI runner (it
# needs a Docker daemon), not inside the container.
#
#   scripts/smoke.sh ghcr.io/owner/dsh:0.2.1-alpha.3
#
# Environment:
#   SMOKE_PORT           host port to publish (default 18080)
#   SMOKE_REQUIRE_BWRAP  set to 1 to make the bubblewrap functional check fatal
#
# What is asserted, and why each one matters:
#   1. /healthz answers "ok"        — Caddy is up and the published port works.
#  1b. / is 401 without credentials — the built-in password gate is on by default,
#      a wrong password is refused, the right one mints a cookie that then carries
#      the session (including for the WebSocket upgrade), and a forged cookie is
#      refused. Without this block a regression could ship the UI wide open.
#   2. / returns 303 + Set-Cookie   — the launch-token bootstrap works, i.e. a
#                                     browser can authenticate without copying a
#                                     token out of the container log.
#   3. a cross-site POST is 403     — DSH's browser-trust fence is intact.
#   4. the native "open document"   — Caddy still gates the endpoints that would
#      endpoint is 403                otherwise hand the page filesystem actions.
#  4b. the password gate works      — no credentials / wrong password / forged cookie
#      all fail, the right password mints a cookie that carries the session (also for
#      the WebSocket upgrade), and the shipped default announces itself.
#  4h. the remote sign-in bridge    — /remote-login is served, gated, and its
#      callback target is only live while a sign-in actually waits; REMOTE_SIGNIN=off
#      leaves upstream behaviour alone.
#   5. bwrap confines a shell       — the sandbox rung Unraid depends on exists.
#   6. both Caddyfiles validate     — a config typo cannot ship.
set -Eeuo pipefail

IMAGE="${1:?usage: smoke.sh <image>}"
PORT="${SMOKE_PORT:-18080}"
NAME="dsh-smoke-$$"
WORKDIR="$(mktemp -d)"
FAILURES=0

cleanup() {
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    # The container chowns the bind mounts to uid 1000, which the runner user is
    # not, so the plain rm can fail; try sudo before giving up.
    rm -rf "${WORKDIR}" 2>/dev/null || sudo rm -rf "${WORKDIR}" 2>/dev/null || true
}
trap cleanup EXIT

# The image serves its own password gate by default (AUTH_MODE=builtin), so every
# request that is meant to reach the application has to authenticate first. The
# gate itself is asserted in its own block below.
SMOKE_PASSWORD='smoke-test-password'
SMOKE_AUTH=(--user "dsh:${SMOKE_PASSWORD}")

pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

mkdir -p "${WORKDIR}/data" "${WORKDIR}/workspace"

printf 'starting %s\n' "${IMAGE}"
# ALLOWED_CLIENTS: the checks below curl from the CI host. Depending on the docker
# networking in use, that request arrives with the bridge gateway as its source
# address (GitHub runners) or with 127.0.0.1 (a plain host), so both are listed
# here. The strict default is asserted separately in the access-control section.
docker run --detach --name "${NAME}" \
    --env 'ALLOWED_CLIENTS=127.0.0.1,172.16.0.0/12' \
    --env "DSH_PASSWORD=${SMOKE_PASSWORD}" \
    --publish "127.0.0.1:${PORT}:8080" \
    --security-opt seccomp=unconfined \
    --security-opt systempaths=unconfined \
    --volume "${WORKDIR}/data:/data" \
    --volume "${WORKDIR}/workspace:/workspace" \
    "${IMAGE}" >/dev/null

ready=0
for _ in $(seq 1 60); do
    if curl --silent --fail --max-time 3 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
        ready=1
        break
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "${NAME}" 2>/dev/null)" != "true" ]]; then
        printf 'container exited early\n'
        docker logs "${NAME}" || true
        exit 1
    fi
    sleep 2
done
if [[ "${ready}" != "1" ]]; then
    printf '/healthz never answered\n'
    docker logs "${NAME}" || true
    exit 1
fi

# 1 — healthz body
if [[ "$(curl --silent --fail --max-time 5 "http://127.0.0.1:${PORT}/healthz")" == "ok" ]]; then
    pass '/healthz answers ok'
else
    fail '/healthz did not answer "ok"'
fi

# 2 — launch-token bootstrap
HEADERS="$(curl --silent --show-error --max-time 5 "${SMOKE_AUTH[@]}" --dump-header - --output /dev/null "http://127.0.0.1:${PORT}/" || true)"
if grep --quiet --ignore-case --extended-regexp '^HTTP/[0-9.]+ 303' <<< "${HEADERS}"; then
    pass '/ answered 303 for the token bootstrap'
else
    fail "/ did not answer 303 (headers: ${HEADERS//$'\n'/ | })"
fi
if grep --quiet --ignore-case --extended-regexp '^set-cookie: *dsh-auth-' <<< "${HEADERS}"; then
    pass 'the bootstrap minted a dsh-auth session cookie'
else
    fail "no dsh-auth cookie in the bootstrap response (headers: ${HEADERS//$'\n'/ | })"
fi

# 3 — cross-site request must be refused by the DSH fence
CROSS_SITE_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "${SMOKE_AUTH[@]}" \
    --request POST \
    --header 'Sec-Fetch-Site: cross-site' \
    --header 'Content-Type: application/json' \
    --data '{}' \
    "http://127.0.0.1:${PORT}/api/settings.describe" || true)"
if [[ "${CROSS_SITE_CODE}" == "403" ]]; then
    pass 'a cross-site /api request is refused (403)'
else
    fail "a cross-site /api request returned ${CROSS_SITE_CODE}, expected 403"
fi

# 4 — Caddy keeps the native settings endpoints shut
NATIVE_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "${SMOKE_AUTH[@]}" \
    "http://127.0.0.1:${PORT}/api/settings.openDocument" || true)"
if [[ "${NATIVE_CODE}" == "403" ]]; then
    pass 'the native open-document endpoint is gated (403)'
else
    fail "the native open-document endpoint returned ${NATIVE_CODE}, expected 403"
fi

# 4b — the built-in password gate. A default install must not be usable by anybody
# who can reach the port, so this is a security assertion, not a convenience one:
# the UI answers 401 without credentials, a wrong password does not get in, the
# right one mints a cookie, that cookie alone is enough afterwards, a forged
# cookie is refused, and the WebSocket upgrade path (which the browser does not
# reliably attach cached HTTP credentials to) accepts the cookie as well.
GATE_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "http://127.0.0.1:${PORT}/" || true)"
GATE_HEADERS="$(curl --silent --dump-header - --output /dev/null --max-time 5 \
    "http://127.0.0.1:${PORT}/" || true)"
if [[ "${GATE_CODE}" == "401" ]] && grep --quiet --ignore-case '^www-authenticate:' <<< "${GATE_HEADERS}"; then
    pass 'password gate: the UI answers 401 (with WWW-Authenticate) without credentials'
else
    fail "password gate: unauthenticated / returned ${GATE_CODE} without a challenge"
fi
WRONG_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --user 'dsh:definitely-not-the-password' "http://127.0.0.1:${PORT}/" || true)"
if [[ "${WRONG_CODE}" == "401" ]]; then
    pass 'password gate: a wrong password is refused (401)'
else
    fail "password gate: a wrong password returned ${WRONG_CODE}, expected 401"
fi
GATE_TOKEN="$(curl --silent --dump-header - --output /dev/null --max-time 5 \
    "${SMOKE_AUTH[@]}" "http://127.0.0.1:${PORT}/" \
    | tr -d '\r' | awk 'tolower($1) == "set-cookie:" && $2 ~ /^dsh_gate=/ { sub(/^dsh_gate=/, "", $2); sub(/;.*/, "", $2); print $2 }' | head -1 || true)"
if [[ -n "${GATE_TOKEN}" ]]; then
    pass 'password gate: the password mints a gate cookie'
else
    fail 'password gate: no dsh_gate cookie was issued after authenticating'
fi
COOKIE_ONLY_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --header "Cookie: dsh_gate=${GATE_TOKEN}" "http://127.0.0.1:${PORT}/" || true)"
if [[ "${COOKIE_ONLY_CODE}" == "303" || "${COOKIE_ONLY_CODE}" == "200" || "${COOKIE_ONLY_CODE}" == "302" ]]; then
    pass 'password gate: the gate cookie alone carries the session'
else
    fail "password gate: cookie-only / returned ${COOKIE_ONLY_CODE}"
fi
FORGED_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --header 'Cookie: dsh_gate=forged-value' "http://127.0.0.1:${PORT}/" || true)"
if [[ "${FORGED_CODE}" == "401" ]]; then
    pass 'password gate: a forged gate cookie is refused (401)'
else
    fail "password gate: a forged cookie returned ${FORGED_CODE}, expected 401"
fi
WS_BLOCKED="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --header 'Connection: Upgrade' --header 'Upgrade: websocket' \
    "http://127.0.0.1:${PORT}/api" || true)"
WS_ALLOWED="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --header "Cookie: dsh_gate=${GATE_TOKEN}" \
    --header 'Connection: Upgrade' --header 'Upgrade: websocket' \
    "http://127.0.0.1:${PORT}/api" || true)"
if [[ "${WS_BLOCKED}" == "401" && "${WS_ALLOWED}" != "401" ]]; then
    pass 'password gate: an upgrade request is refused without the cookie and passed with it'
else
    fail "password gate: upgrade returned ${WS_BLOCKED} unauthenticated and ${WS_ALLOWED} with the cookie"
fi

# 4c — the password the Unraid template ships must announce itself. Many operators
# never open the README, so this log line is the only signal that the gate is still
# protecting nothing (the default is public).
DEFAULT_NAME="${NAME}-defaultpw"
DEFAULT_PORT=$((PORT + 2))
mkdir -p "${WORKDIR}/data-default" "${WORKDIR}/workspace-default"
docker run --detach --name "${DEFAULT_NAME}" \
    --env 'ALLOWED_CLIENTS=127.0.0.1,172.16.0.0/12' \
    --env 'DSH_PASSWORD=12345678' \
    --publish "127.0.0.1:${DEFAULT_PORT}:8080" \
    --volume "${WORKDIR}/data-default:/data" \
    --volume "${WORKDIR}/workspace-default:/workspace" \
    "${IMAGE}" >/dev/null
for _ in $(seq 1 30); do
    if curl --silent --fail --max-time 3 "http://127.0.0.1:${DEFAULT_PORT}/healthz" >/dev/null 2>&1; then break; fi
    sleep 2
done
DEFAULT_LOG="$(docker logs "${DEFAULT_NAME}" 2>&1)"
if grep --quiet 'SECURITY: 口令仍是默认值' <<<"${DEFAULT_LOG}" \
    && grep --quiet 'SECURITY: the password is still the default' <<<"${DEFAULT_LOG}"; then
    pass 'the default password is announced in both Chinese and English'
else
    fail 'the default password warning is missing one of its two lines (Chinese/English)'
fi
if grep --quiet "用户名是 'dsh'" <<<"${DEFAULT_LOG}"; then
    pass 'the warning also names the account to sign in with'
else
    fail 'the warning does not say which user name to use'
fi
# "starting Caddy ... (auth=...)" is the last line the entrypoint prints, so a slow
# runner can still be missing it while /healthz already answers — which is exactly how
# this assertion failed once in CI and passed locally. Poll the log instead of racing it.
AUTH_MODE_LINE=''
for _ in $(seq 1 30); do
    AUTH_MODE_LINE="$(docker logs "${DEFAULT_NAME}" 2>&1 | grep '(auth=' | tail -1)"
    [[ -n "${AUTH_MODE_LINE}" ]] && break
    sleep 2
done
if [[ "${AUTH_MODE_LINE}" == *'(auth=builtin)'* ]]; then
    pass 'the default AUTH_MODE is builtin (the gate is on out of the box)'
else
    fail "the image did not start with auth=builtin by default (log said: ${AUTH_MODE_LINE:-nothing yet})"
fi
docker rm -f "${DEFAULT_NAME}" >/dev/null 2>&1 || true

# 4d — the user name is a setting (the template ships it as a required field). A login
# prompt that asks for a name nobody can find is the failure this guards against.
USER_NAME="${NAME}-username"
USER_PORT=$((PORT + 3))
docker run --detach --name "${USER_NAME}" \
    --env 'ALLOWED_CLIENTS=127.0.0.1,172.16.0.0/12' \
    --env 'DSH_PASSWORD=smoke-test-password' \
    --env 'AUTH_USER=operator' \
    --publish "127.0.0.1:${USER_PORT}:8080" \
    --volume "${WORKDIR}/data-user:/data" \
    --volume "${WORKDIR}/workspace-user:/workspace" \
    "${IMAGE}" >/dev/null
for _ in $(seq 1 30); do
    if curl --silent --fail --max-time 3 "http://127.0.0.1:${USER_PORT}/healthz" >/dev/null 2>&1; then break; fi
    sleep 2
done
if [[ "$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 --user 'operator:smoke-test-password' "http://127.0.0.1:${USER_PORT}/")" == '303' ]]; then
    pass 'the configured user name signs in (AUTH_USER)'
else
    fail 'AUTH_USER was ignored: the configured user name could not sign in'
fi
if [[ "$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 --user 'dsh:smoke-test-password' "http://127.0.0.1:${USER_PORT}/")" == '401' ]]; then
    pass 'the default user name stops working once AUTH_USER names another one'
else
    fail 'both the default and the configured user name were accepted'
fi
docker rm -f "${USER_NAME}" >/dev/null 2>&1 || true

# 4e — a user name that would break the Caddyfile directive must be refused outright
if docker run --rm \
    --env 'DSH_PASSWORD=smoke-test-password' \
    --env 'AUTH_USER=bad user' \
    "${IMAGE}" >/dev/null 2>&1; then
    fail 'a user name with a space was accepted'
else
    pass 'an invalid AUTH_USER refuses to start the container'
fi

# 4f — /renew must rescue a browser whose DSH session cookie went stale. That is not
# hypothetical: a stale cookie makes DSH answer 401 while the bootstrap rule stays out
# of the way (it only fires when no dsh-auth-* cookie is present at all), so without
# this route the only cure is clearing cookies by hand.
STALE_COOKIE='dsh-auth-loopback=stale-value-from-another-instance'
STALE_HEADERS="$(curl --silent --dump-header - --output /dev/null --max-time 5 \
    "${SMOKE_AUTH[@]}" --cookie "${STALE_COOKIE}" "http://127.0.0.1:${PORT}/")"
CODE_STALE="$(printf '%s' "${STALE_HEADERS}" | head -1 | awk '{print $2}')"
STALE_LOCATION="$(printf '%s' "${STALE_HEADERS}" | grep --ignore-case '^location:' | tr -d '\r' | awk '{print $2}')"
if [[ "${CODE_STALE}" == '302' && "${STALE_LOCATION}" == '/renew' ]]; then
    pass 'a stale session cookie is redirected to /renew instead of dead-ending on 401'
else
    fail "a stale dsh-auth cookie answered ${CODE_STALE:-?} -> ${STALE_LOCATION:-nowhere}, expected 302 -> /renew"
fi
if printf '%s' "${STALE_HEADERS}" | grep --ignore-case --quiet '^set-cookie: dsh_renew=1'; then
    pass 'the heal marks itself, so it cannot bounce forever'
else
    fail 'the healing redirect did not set its one-shot marker cookie'
fi
RENEW_LOCATION="$(curl --silent --dump-header - --output /dev/null --max-time 5 \
    "${SMOKE_AUTH[@]}" --cookie "${STALE_COOKIE}" "http://127.0.0.1:${PORT}/renew" \
    | grep --ignore-case '^location:' | tr -d '\r' | awk '{print $2}')"
if [[ "${RENEW_LOCATION}" == /?token=* ]]; then
    pass '/renew replays the launch token (the one-click recovery step)'
else
    fail "/renew answered ${RENEW_LOCATION:-no Location} instead of /?token=..."
fi
FRESH_COOKIE="$(curl --silent --dump-header - --output /dev/null --max-time 5 \
    "${SMOKE_AUTH[@]}" --cookie "${STALE_COOKIE}" "http://127.0.0.1:${PORT}${RENEW_LOCATION}" \
    | grep --ignore-case '^set-cookie: dsh-auth-' | head -1 | sed 's/^[Ss]et-[Cc]ookie: //' | cut -d';' -f1 | tr -d '\r')"
if [[ -n "${FRESH_COOKIE}" ]]; then
    pass '/renew makes DSH mint a fresh session cookie despite the stale one'
else
    fail 'following /renew did not mint a fresh dsh-auth cookie'
fi
CODE_RESCUED="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "${SMOKE_AUTH[@]}" --cookie "${FRESH_COOKIE}" "http://127.0.0.1:${PORT}/")"
if [[ "${CODE_RESCUED}" != '401' ]]; then
    pass "the rescued session reaches the app (HTTP ${CODE_RESCUED})"
else
    fail 'the rescued session still answers 401'
fi

# 4g — the heal must happen without the operator doing anything: a stale cookie on a
# document request is answered with 401 by DSH, which the route above turns into a
# detour through /renew. Following redirects the way a browser does must land on the app.
AUTO_JAR="${WORKDIR}/auto-cookies.txt"
AUTO_CODE="$(curl --silent --location --output /dev/null --write-out '%{http_code}' --max-time 20 \
    "${SMOKE_AUTH[@]}" --cookie "${STALE_COOKIE}" --cookie-jar "${AUTO_JAR}" "http://127.0.0.1:${PORT}/")"
if [[ "${AUTO_CODE}" == '200' ]]; then
    pass 'a stale cookie heals itself (no manual /renew, final HTTP 200)'
else
    fail "the automatic heal ended on HTTP ${AUTO_CODE}, expected 200"
fi
if grep --quiet 'dsh-auth-' "${AUTO_JAR}" 2>/dev/null; then
    pass 'the automatic heal stored a fresh session cookie'
else
    fail 'the automatic heal did not store a fresh dsh-auth cookie'
fi

# 4h — the remote sign-in bridge (docs/remote-signin.md). Upstream refuses an account
# sign-in unless the browser's own origin is a loopback address — measured against the
# platform, `redirect_uri=https://<host>/...` answers 50005 while
# `redirect_uri=http://127.0.0.1:<port>/...` answers code 0 — and no browser on the LAN
# or on the internet can reach such an address. The image therefore claims one and
# serves a page that carries the undelivered callback back to DSH's own route.
#
# Three things have to hold, and each has failed in some design: the overlay must load
# (otherwise the sign-in still dies locally), the page must be served and gated like
# every other surface, and the path it targets must be reachable *only* while an
# attempt waits — a permanently live /oauth/callback would be a worse design than the
# bug it fixes.
BRIDGE_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "${SMOKE_AUTH[@]}" "http://127.0.0.1:${PORT}/remote-login" || true)"
BRIDGE_BODY="$(curl --silent --max-time 5 "${SMOKE_AUTH[@]}" "http://127.0.0.1:${PORT}/remote-login" || true)"
BRIDGE_TYPE="$(curl --silent --output /dev/null --write-out '%{content_type}' --max-time 5 \
    "${SMOKE_AUTH[@]}" "http://127.0.0.1:${PORT}/remote-login" || true)"
if [[ "${BRIDGE_CODE}" == "200" && "${BRIDGE_TYPE}" == text/html* ]] \
    && grep --quiet -- '/oauth/callback' <<< "${BRIDGE_BODY}" \
    && grep --quiet -- 'state' <<< "${BRIDGE_BODY}"; then
    pass '/remote-login serves the remote sign-in bridge page'
else
    fail "/remote-login answered ${BRIDGE_CODE} (${BRIDGE_TYPE}) without the expected callback markup"
fi
if [[ "$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "http://127.0.0.1:${PORT}/remote-login" || true)" == "401" ]]; then
    pass 'the bridge page is behind the same gate as the UI (401 without credentials)'
else
    fail 'the bridge page is reachable without authenticating'
fi
CALLBACK_IDLE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "${SMOKE_AUTH[@]}" "http://127.0.0.1:${PORT}/oauth/callback?code=smoke-test&state=smoke-test" || true)"
if [[ "${CALLBACK_IDLE}" == "404" ]]; then
    pass 'the callback path is dead without a pending sign-in (the page alone completes nothing)'
else
    fail "no sign-in is pending, yet /oauth/callback answered ${CALLBACK_IDLE}, expected 404"
fi
OVERLAY_LINE=''
for _ in $(seq 1 30); do
    OVERLAY_LINE="$(docker logs "${NAME}" 2>&1 | grep '\[remote-signin\] active' | tail -1)"
    [[ -n "${OVERLAY_LINE}" ]] && break
    sleep 2
done
if [[ "${OVERLAY_LINE}" == *'loopback claim'* ]]; then
    pass 'the remote sign-in overlay loaded and claimed its loopback origin'
else
    fail "the remote sign-in overlay never reported itself active (log said: ${OVERLAY_LINE:-nothing})"
fi

# 4i — REMOTE_SIGNIN=off is the documented escape hatch back to upstream behaviour, and
# a value nobody implements must not be guessed at. Both are cheap to assert and both
# are the kind of thing that silently drifts.
OFF_NAME="${NAME}-rs-off"
OFF_PORT=$((PORT + 4))
mkdir -p "${WORKDIR}/data-rs-off" "${WORKDIR}/workspace-rs-off"
docker run --detach --name "${OFF_NAME}" \
    --env 'ALLOWED_CLIENTS=127.0.0.1,172.16.0.0/12' \
    --env 'DSH_PASSWORD=smoke-test-password' \
    --env 'REMOTE_SIGNIN=off' \
    --publish "127.0.0.1:${OFF_PORT}:8080" \
    --volume "${WORKDIR}/data-rs-off:/data" \
    --volume "${WORKDIR}/workspace-rs-off:/workspace" \
    "${IMAGE}" >/dev/null
for _ in $(seq 1 30); do
    if curl --silent --fail --max-time 3 "http://127.0.0.1:${OFF_PORT}/healthz" >/dev/null 2>&1; then break; fi
    sleep 2
done
OFF_LOG="$(docker logs "${OFF_NAME}" 2>&1)"
if grep --quiet 'remote sign-in: off' <<<"${OFF_LOG}" && ! grep --quiet '\[remote-signin\] active' <<<"${OFF_LOG}"; then
    pass 'REMOTE_SIGNIN=off leaves the overlay unloaded'
else
    fail 'REMOTE_SIGNIN=off either kept the overlay or never said so in the log'
fi
docker rm -f "${OFF_NAME}" >/dev/null 2>&1 || true
if docker run --rm \
    --env 'DSH_PASSWORD=smoke-test-password' \
    --env 'REMOTE_SIGNIN=sometimes' \
    "${IMAGE}" >/dev/null 2>&1; then
    fail 'an unsupported REMOTE_SIGNIN value was accepted'
else
    pass 'an unsupported REMOTE_SIGNIN value refuses to start the container'
fi

# 5 — bubblewrap
if docker exec "${NAME}" bwrap --version >/dev/null 2>&1; then
    pass 'bubblewrap is installed'
else
    fail 'bubblewrap is missing from the image'
fi
if docker exec "${NAME}" setpriv --reuid 1000 --regid 1000 --init-groups \
    bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent \
    --tmpfs /tmp --bind /workspace /workspace -- /bin/sh -c 'echo SANDBOX_OK' 2>/dev/null | grep --quiet SANDBOX_OK; then
    pass 'bubblewrap confines a shell inside the container'
else
    if [[ "${SMOKE_REQUIRE_BWRAP:-0}" == "1" ]]; then
        fail 'bubblewrap could not create a namespace (see docs/unraid-sandbox.md)'
    else
        printf 'note bubblewrap could not create a namespace here; CI runners restrict unprivileged user namespaces, so this is not fatal unless SMOKE_REQUIRE_BWRAP=1\n'
    fi
fi

# 5b — the tool surface the deployment needs, and a writable HOME.
#
# Learnt the hard way: an image that simply omitted openssh-client could not reach
# its host at all (and git-over-ssh remotes stopped authenticating), while pnpm and
# unzip had also gone missing from a build that otherwise looked fine. HOME is the
# second half of the same story — left at /root while the entrypoint drops to
# uid 1000, every ~-based path (ssh config, git config, tool caches) fails with a
# permission error that looks like anything but a HOME problem.
TOOL_MISSING=""
for tool in ssh git curl jq rg unzip less pnpm node bwrap setpriv; do
    docker exec "${NAME}" sh -c "command -v ${tool} >/dev/null 2>&1" || TOOL_MISSING="${TOOL_MISSING} ${tool}"
done
if [[ -z "${TOOL_MISSING}" ]]; then
    pass 'the image ships the expected tools (ssh, git, curl, jq, rg, unzip, less, pnpm, node, bwrap)'
else
    fail "the image is missing tools this deployment needs:${TOOL_MISSING}"
fi
if docker exec --user 1000:1000 "${NAME}" sh -c "test -d \"\$HOME/workspace\" && test -r \"\$HOME/workspace\"" 2>/dev/null; then
    pass 'the workspace is reachable from HOME (where the directory picker opens)'
else
    fail 'the workspace is not reachable from the home directory; the directory picker would open on an empty home'
fi
CONTAINER_HOME="$(docker exec --user 1000:1000 "${NAME}" sh -c "printf %s \"\${HOME:-unset}\"" 2>/dev/null)"
if docker exec --user 1000:1000 "${NAME}" sh -c "test -w \"\${HOME:-/nonexistent}\"" 2>/dev/null; then
    pass "HOME (${CONTAINER_HOME}) is writable by the account the container runs as"
else
    fail "HOME (${CONTAINER_HOME}) is not writable by the account the container runs as; ~/.ssh and tool caches will fail"
fi

# 6 — both Caddy configs must validate
for config in edge lan; do
    if docker exec \
        --env PORT=8080 \
        --env DSH_INTERNAL_PORT=3080 \
        --env PUBLIC_ORIGIN=https://smoke.example \
        --env DSH_UPSTREAM_HOST=smoke.example \
        --env DSH_LAUNCH_TOKEN=smoke \
        "${NAME}" caddy validate --config "/etc/caddy/Caddyfile.${config}" --adapter caddyfile >/dev/null 2>&1; then
        pass "Caddyfile.${config} validates"
    else
        fail "Caddyfile.${config} does not validate"
        docker exec --env PORT=8080 --env DSH_INTERNAL_PORT=3080 --env PUBLIC_ORIGIN=https://smoke.example \
            --env DSH_UPSTREAM_HOST=smoke.example --env DSH_LAUNCH_TOKEN=smoke \
            "${NAME}" caddy validate --config "/etc/caddy/Caddyfile.${config}" --adapter caddyfile || true
    fi
done

if [[ "${FAILURES}" -ne 0 ]]; then
    printf '\n%s check(s) failed; container log follows\n' "${FAILURES}"
    docker logs "${NAME}" || true
    exit 1
fi

# 7 — edge mode: PUBLIC_URL set. Caddy rewrites Host to that authority (passed to
#     DSH as --trusted-host) and refuses any request carrying a different Origin.
#     The container above ran in lan mode, so this path was never exercised.
EDGE_NAME="dsh-smoke-edge-$$"
EDGE_PORT=$((PORT + 1))
mkdir -p "${WORKDIR}/data-edge" "${WORKDIR}/workspace-edge"
docker run --detach --name "${EDGE_NAME}" \
    --publish "127.0.0.1:${EDGE_PORT}:8080" \
    --security-opt seccomp=unconfined \
    --security-opt systempaths=unconfined \
    --volume "${WORKDIR}/data-edge:/data" \
    --volume "${WORKDIR}/workspace-edge:/workspace" \
    --env 'ALLOWED_CLIENTS=127.0.0.1,172.16.0.0/12' \
    --env "PUBLIC_URL=http://127.0.0.1:${EDGE_PORT}" \
    --env 'AUTH_MODE=none' \
    "${IMAGE}" >/dev/null

edge_ready=0
for _ in $(seq 1 60); do
    if curl --silent --fail --max-time 3 "http://127.0.0.1:${EDGE_PORT}/healthz" >/dev/null 2>&1; then edge_ready=1; break; fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "${EDGE_NAME}" 2>/dev/null)" != "true" ]]; then break; fi
    sleep 2
done
if [[ "${edge_ready}" != "1" ]]; then
    fail "edge mode: /healthz never answered"
    docker logs "${EDGE_NAME}" || true
else
    pass "edge mode: container starts with PUBLIC_URL set"
fi

# This container runs AUTH_MODE=none on purpose: its subject is the Host/Origin
# contract with the proxy in front, and that is exactly the documented setting when
# something else already authenticates. The gate assertions above cover builtin.
EDGE_NO_GATE_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "http://127.0.0.1:${EDGE_PORT}/" || true)"
if [[ "${EDGE_NO_GATE_CODE}" != "401" ]]; then
    pass 'AUTH_MODE=none serves the UI without a challenge (delegated authentication)'
else
    fail 'AUTH_MODE=none still demanded credentials'
fi

EDGE_ORIGIN="http://127.0.0.1:${EDGE_PORT}"
SAME_ORIGIN_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --request POST --header "Origin: ${EDGE_ORIGIN}" --header 'Content-Type: application/json' \
    --data '{}' "http://127.0.0.1:${EDGE_PORT}/api/settings.describe" || true)"
FOREIGN_ORIGIN_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    --request POST --header 'Origin: http://evil.example' --header 'Content-Type: application/json' \
    --data '{}' "http://127.0.0.1:${EDGE_PORT}/api/settings.describe" || true)"
if [[ "${FOREIGN_ORIGIN_CODE}" == "403" ]]; then
    pass "edge mode: a foreign Origin is refused (403)"
else
    fail "edge mode: foreign Origin returned ${FOREIGN_ORIGIN_CODE}, expected 403"
fi
if [[ "${SAME_ORIGIN_CODE}" != "403" ]]; then
    pass "edge mode: the advertised Origin reaches DSH (${SAME_ORIGIN_CODE})"
else
    fail "edge mode: the advertised Origin was refused (403), so the Host rewrite/trusted-host wiring is wrong"
fi

docker rm -f "${EDGE_NAME}" >/dev/null 2>&1 || true

# 9 — access control (ALLOWED_CLIENTS). The allowlist is enforced by a Caddy
#     handle block; getting that placement wrong is silent (the request simply
#     reaches the app), so it is asserted here from a real foreign address: a
#     second container on its own network, whose address is never loopback.
AC_NET="dsh-smoke-net-$$"
AC_NAME="dsh-smoke-ac-$$"
mkdir -p "${WORKDIR}/data-ac" "${WORKDIR}/workspace-ac"
if docker network create "${AC_NET}" >/dev/null 2>&1; then
    docker run --detach --name "${AC_NAME}" --network "${AC_NET}" \
        --volume "${WORKDIR}/data-ac:/data" \
        --volume "${WORKDIR}/workspace-ac:/workspace" \
        --env 'ALLOWED_CLIENTS=127.0.0.1' \
        "${IMAGE}" >/dev/null

    ac_ready=0
    for _ in $(seq 1 60); do
        if docker exec "${AC_NAME}" curl --silent --fail --max-time 3 http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
            ac_ready=1
            break
        fi
        if [[ "$(docker inspect --format '{{.State.Running}}' "${AC_NAME}" 2>/dev/null)" != "true" ]]; then break; fi
        sleep 2
    done

    if [[ "${ac_ready}" != "1" ]]; then
        fail 'access control: the container never answered on loopback'
        docker logs "${AC_NAME}" || true
    else
        pass 'access control: loopback is always allowed (healthcheck path works)'
        CLIENT_IP="$(docker run --rm --network "${AC_NET}" --entrypoint sh "${IMAGE}" -c 'hostname -i' 2>/dev/null | tr -d '\r' | awk '{print $1}')"
        DENIED_CODE="$(docker run --rm --network "${AC_NET}" --entrypoint /usr/bin/curl "${IMAGE}" \
            --silent --output /dev/null --write-out '%{http_code}' --max-time 8 \
            "http://${AC_NAME}:8080/healthz" || true)"
        if [[ "${DENIED_CODE}" == "403" ]]; then
            pass "access control: ${CLIENT_IP:-a foreign client} is refused (403)"
        else
            fail "access control: a client outside ALLOWED_CLIENTS got ${DENIED_CODE}, expected 403"
        fi

        CLIENT_CIDR="$(awk -F. '{print $1"."$2"."$3".0/24"}' <<< "${CLIENT_IP}")"
        docker rm -f "${AC_NAME}" >/dev/null 2>&1 || true
        docker run --detach --name "${AC_NAME}" --network "${AC_NET}" \
            --volume "${WORKDIR}/data-ac:/data" \
            --volume "${WORKDIR}/workspace-ac:/workspace" \
            --env "ALLOWED_CLIENTS=127.0.0.1,${CLIENT_CIDR}" \
            "${IMAGE}" >/dev/null
        for _ in $(seq 1 60); do
            docker exec "${AC_NAME}" curl --silent --fail --max-time 3 http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break
            sleep 2
        done
        ALLOWED_CODE="$(docker run --rm --network "${AC_NET}" --entrypoint /usr/bin/curl "${IMAGE}" \
            --silent --output /dev/null --write-out '%{http_code}' --max-time 8 \
            "http://${AC_NAME}:8080/healthz" || true)"
        if [[ "${ALLOWED_CODE}" == "200" ]]; then
            pass "access control: ${CLIENT_CIDR} is allowed once listed (200)"
        else
            fail "access control: ${CLIENT_CIDR} returned ${ALLOWED_CODE} after being listed, expected 200"
        fi
    fi

    docker rm -f "${AC_NAME}" >/dev/null 2>&1 || true
    docker network rm "${AC_NET}" >/dev/null 2>&1 || true
else
    printf 'skip access-control check: could not create a test network\n'
fi

printf '\nall smoke checks passed\n'
