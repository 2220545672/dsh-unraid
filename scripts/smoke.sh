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
#   2. / returns 303 + Set-Cookie   — the launch-token bootstrap works, i.e. a
#                                     browser can authenticate without copying a
#                                     token out of the container log.
#   3. a cross-site POST is 403     — DSH's browser-trust fence is intact.
#   4. the native "open document"   — Caddy still gates the endpoints that would
#      endpoint is 403                otherwise hand the page filesystem actions.
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

pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

mkdir -p "${WORKDIR}/data" "${WORKDIR}/workspace"

printf 'starting %s\n' "${IMAGE}"
docker run --detach --name "${NAME}" \
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
HEADERS="$(curl --silent --show-error --max-time 5 --dump-header - --output /dev/null "http://127.0.0.1:${PORT}/" || true)"
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
    "http://127.0.0.1:${PORT}/api/settings.openDocument" || true)"
if [[ "${NATIVE_CODE}" == "403" ]]; then
    pass 'the native open-document endpoint is gated (403)'
else
    fail "the native open-document endpoint returned ${NATIVE_CODE}, expected 403"
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

printf '\nall smoke checks passed\n'
