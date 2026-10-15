#!/usr/bin/env bash
#
# DeepSeek Harness container entrypoint.
#
# Process model (same shape as the other community builds, deliberately):
#
#   Caddy :PORT (0.0.0.0)  --proxy-->  dsh web 127.0.0.1:DSH_INTERNAL_PORT
#
# `dsh web` refuses wildcard bind addresses, and its browser-trust fence
# (node_modules/@deepseek-ai/dsh-client-connection) requires the Host header to
# be loopback / the listener bind IP / a declared --trusted-host, with any
# attached Origin matching that Host. Caddy therefore owns the listener, injects
# the launch token into the browser's first navigation, and presents DSH a Host
# it will accept. Two modes:
#
#   edge : PUBLIC_URL set. Caddy forwards Host=<authority>, keeps Origin, and
#          rejects any request whose Origin is not PUBLIC_URL. Use this behind
#          SWAG/Authelia (or any HTTPS front end).
#   lan  : PUBLIC_URL empty. Caddy forwards Host=127.0.0.1:<internal>, strips
#          Origin, and warns. DNS-rebinding and cross-site defence stay in
#          force: the Host fence cannot be forged by a rebound browser, and the
#          fence still rejects Sec-Fetch-Site: cross-site.
#
# AUTH_MODE is intentionally limited to `none`: authentication belongs to the
# edge proxy. Anything else fails closed instead of pretending to be safe.
set -Eeuo pipefail

# The image's unprivileged `node` account. Fixed on purpose: the layered
# filesystem, /data and /workspace ownership all assume it, so making it
# configurable at runtime would only produce permission errors.
APP_UID=1000
APP_GID=1000

PORT="${PORT:-8080}"
DSH_INTERNAL_PORT="${DSH_INTERNAL_PORT:-3080}"
AUTH_MODE="${AUTH_MODE:-none}"
DSH_HOME="${DSH_HOME:-/data/dsh}"
DSH_AGENTS_HOME="${DSH_AGENTS_HOME:-${DSH_HOME}/agents}"
DSH_WORKSPACE="${DSH_WORKSPACE:-/workspace}"
DSH_TRUSTED_HOSTS="${DSH_TRUSTED_HOSTS:-}"
PUBLIC_URL="${PUBLIC_URL:-}"

CADDY_DIR="/etc/caddy"
CADDY_CONFIG_HOME="${DSH_HOME%/dsh}/caddy/config"
CADDY_DATA_HOME="${DSH_HOME%/dsh}/caddy/data"
DSH_STARTUP_LOG="${TMPDIR:-/tmp}/dsh-startup-$$.log"
DSH_VERSION_FILE="/etc/dsh-version"

DSH_PID=""
CADDY_PID=""
DSH_LAUNCH_TOKEN=""
DSH_UPSTREAM_HOST=""
PUBLIC_ORIGIN=""
EXTRA_TRUSTED_HOSTS=()

log() { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] WARNING: %s\n' "$*" >&2; }
fatal() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

validate_port() {
    local name="$1" value="$2" numeric
    [[ "${value}" =~ ^[0-9]{1,5}$ ]] || fatal "${name} must be an integer between 1 and 65535 (got '${value}')"
    numeric=$((10#${value}))
    (( numeric >= 1 && numeric <= 65535 )) || fatal "${name} must be between 1 and 65535 (got '${value}')"
}

read_image_version() {
    [[ -r "${DSH_VERSION_FILE}" ]] || return 0
    local line
    while IFS= read -r line; do
        [[ "${line}" == DSH_VERSION=* ]] && printf '%s' "${line#DSH_VERSION=}" && return 0
    done < "${DSH_VERSION_FILE}"
}

prepare_directory() {
    local path="$1" current="" part
    local -a parts=()
    [[ "${path}" == /* ]] || fatal "persistent paths must be absolute: ${path}"
    IFS='/' read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "${part}" ]] || continue
        current="${current}/${part}"
        [[ -L "${current}" ]] && fatal "${current} must not be a symbolic link"
        [[ -e "${current}" && ! -d "${current}" ]] && fatal "${current} must be a directory"
    done
    install -d -m 0750 -o "${APP_UID}" -g "${APP_GID}" "${path}"
}

as_app_user() {
    # util-linux is always present in the base image; no gosu needed.
    setpriv --reuid "${APP_UID}" --regid "${APP_GID}" --init-groups -- "$@"
}

shutdown_children() {
    local pid
    for pid in "${CADDY_PID}" "${DSH_PID}"; do
        if [[ -n "${pid}" ]]; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done
    rm -f "${DSH_STARTUP_LOG}" 2>/dev/null || true
}

# The bundled Caddyfiles carry two markers. ACCESS_CONTROL is replaced by the
# rules built from ALLOWED_CLIENTS; TRUSTED_PROXIES is replaced by the Caddy
# trusted-proxy options when TRUSTED_PROXY_CIDRS is set (and removed otherwise).
render_caddyfile() {
    local source="$1" target="$2" line
    : > "${target}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        case "${line}" in
            *'# ACCESS_CONTROL'*)
                printf '%s\n' "${ACCESS_BLOCK[@]}" >> "${target}"
                ;;
            *'# TRUSTED_PROXIES'*)
                if (( ${#TRUSTED_BLOCK[@]} > 0 )); then
                    printf '%s\n' "${TRUSTED_BLOCK[@]}" >> "${target}"
                fi
                ;;
            *)
                printf '%s\n' "${line}" >> "${target}"
                ;;
        esac
    done < "${source}"
}

# ------------------------------------------------------------ access control

# ALLOWED_CLIENTS — the only peers that may talk to this container. IP addresses
# and CIDRs are matched against the peer address, hostnames against the Host
# header. Loopback is always permitted so the bundled healthcheck keeps working
# however the list is edited.
ALLOWED_CLIENTS="${ALLOWED_CLIENTS:-127.0.0.1}"
ALLOWED_IPS=("127.0.0.1" "::1")
ALLOWED_HOSTS=()
IFS=',' read -r -a allowed_entries <<< "${ALLOWED_CLIENTS}"
for entry in "${allowed_entries[@]}"; do
    entry="$(trim "${entry}")"
    [[ -n "${entry}" ]] || continue
    if [[ "${entry}" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ && "${entry}" =~ [0-9] ]]; then
        # skip duplicates so the generated matcher stays readable
        duplicate=0
        for seen in "${ALLOWED_IPS[@]}"; do [[ "${seen}" == "${entry}" ]] && duplicate=1; done
        (( duplicate == 1 )) || ALLOWED_IPS+=("${entry}")
    elif [[ "${entry}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]]; then
        duplicate=0
        for seen in "${ALLOWED_HOSTS[@]}"; do [[ "${seen}" == "${entry}" ]] && duplicate=1; done
        (( duplicate == 1 )) || ALLOWED_HOSTS+=("${entry}")
    else
        fatal "ALLOWED_CLIENTS entries must be IP addresses, CIDRs or hostnames (got '${entry}')"
    fi
done
(( ${#ALLOWED_IPS[@]} <= 32 )) || fatal "ALLOWED_CLIENTS lists too many addresses"
(( ${#ALLOWED_HOSTS[@]} <= 32 )) || fatal "ALLOWED_CLIENTS lists too many hostnames"

# TRUSTED_PROXY_CIDRS — optional. When a reverse proxy sits in front, list its
# addresses here and Caddy will read the real client address from
# X-Forwarded-For *only* for connections coming from those peers. Never list a
# range that untrusted clients can originate from: they could then forge XFF and
# talk their way past ALLOWED_CLIENTS.
TRUSTED_PROXY_CIDRS="${TRUSTED_PROXY_CIDRS:-}"
TRUSTED_PROXY_LIST=()
if [[ -n "${TRUSTED_PROXY_CIDRS}" ]]; then
    IFS=',' read -r -a proxy_entries <<< "${TRUSTED_PROXY_CIDRS}"
    for entry in "${proxy_entries[@]}"; do
        entry="$(trim "${entry}")"
        [[ -n "${entry}" ]] || continue
        [[ "${entry}" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ && "${entry}" =~ [0-9] ]] \
            || fatal "TRUSTED_PROXY_CIDRS entries must be IP addresses or CIDRs (got '${entry}')"
        TRUSTED_PROXY_LIST+=("${entry}")
    done
    (( ${#TRUSTED_PROXY_LIST[@]} <= 16 )) || fatal "TRUSTED_PROXY_CIDRS lists too many entries"
fi

# ---------------------------------------------------------------- validation

[[ "${AUTH_MODE}" == "none" ]] || fatal "AUTH_MODE='${AUTH_MODE}' is not supported by this image; it serves no authentication of its own (set AUTH_MODE=none and authenticate at the edge: SWAG/Authelia, VPN, or a trusted LAN)"

validate_port PORT "${PORT}"
validate_port DSH_INTERNAL_PORT "${DSH_INTERNAL_PORT}"
PORT=$((10#${PORT}))
DSH_INTERNAL_PORT=$((10#${DSH_INTERNAL_PORT}))
(( PORT != DSH_INTERNAL_PORT )) || fatal "PORT and DSH_INTERNAL_PORT must differ"

if [[ -n "${PUBLIC_URL}" ]]; then
    parsed="$(node -e '
      const raw = process.argv[1];
      let url;
      try { url = new URL(raw); } catch { process.exit(2); }
      if (!["http:", "https:"].includes(url.protocol)) process.exit(3);
      if (url.username || url.password || url.pathname !== "/" || url.search || url.hash) process.exit(4);
      process.stdout.write(url.origin + "\n" + url.host + "\n");
    ' "${PUBLIC_URL}")" || fatal "PUBLIC_URL must be an http(s) origin without credentials, path, query, or fragment (got '${PUBLIC_URL}')"
    PUBLIC_ORIGIN="$(sed -n '1p' <<< "${parsed}")"
    DSH_UPSTREAM_HOST="$(sed -n '2p' <<< "${parsed}")"
    [[ -n "${DSH_UPSTREAM_HOST}" ]] || fatal "PUBLIC_URL has no authority"
    if [[ "${PUBLIC_ORIGIN}" == http://* ]]; then
        warn "PUBLIC_URL is plain HTTP; use HTTPS at the edge before exposing this to an untrusted network"
    fi
fi

if [[ -n "${DSH_TRUSTED_HOSTS}" ]]; then
    IFS=',' read -r -a raw_hosts <<< "${DSH_TRUSTED_HOSTS}"
    for host in "${raw_hosts[@]}"; do
        host="$(trim "${host}")"
        [[ -n "${host}" ]] || continue
        [[ "${host}" =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:([0-9]{1,5}))?$ ]] \
            || fatal "DSH_TRUSTED_HOSTS entries must be bare host[:port] authorities (got '${host}')"
        port="${BASH_REMATCH[3]:-}"
        if [[ -n "${port}" ]] && (( 10#${port} < 1 || 10#${port} > 65535 )); then
            fatal "DSH_TRUSTED_HOSTS entry has an out-of-range port: ${host}"
        fi
        EXTRA_TRUSTED_HOSTS+=("${host}")
    done
    if [[ -z "${PUBLIC_URL}" ]]; then
        warn "DSH_TRUSTED_HOSTS is ignored without PUBLIC_URL: in lan mode the Host presented to DSH is loopback"
        EXTRA_TRUSTED_HOSTS=()
    fi
fi

# ------------------------------------------------------------------ preparation

prepare_directory /data
prepare_directory "${DSH_HOME}"
prepare_directory "${DSH_AGENTS_HOME}"
prepare_directory "${DSH_WORKSPACE}"
prepare_directory "${CADDY_CONFIG_HOME}"
prepare_directory "${CADDY_DATA_HOME}"

# HOME must be readable and writable by the account we drop to. The base image
# leaves it at /root, which uid 1000 cannot even list, and DSH surfaces that as a
# bewildering failure deep inside the UI ("cannot list /root: EACCES") when a file
# or workspace picker opens. The image sets HOME correctly; this repairs the case
# anyway, because an unwritable HOME stays silent until something opens a picker,
# and a forked or re-based build should not have to rediscover it.
if [[ ! -d "${HOME}" || ! -w "${HOME}" ]]; then
    fallback_home="/home/node"
    warn "HOME='${HOME}' is not writable by uid ${APP_UID}; using ${fallback_home} instead"
    install -d -o "${APP_UID}" -g "${APP_GID}" -m 0755 "${fallback_home}"
    export HOME="${fallback_home}"
fi

if ! awk '$5 == "/data" { found = 1 } END { exit found ? 0 : 1 }' /proc/self/mountinfo; then
    warn "/data is not a mount point: sessions, credentials and the agent home will be lost when this container is recreated"
fi

DSH_VERSION="$(read_image_version || true)"

if [[ -n "${PUBLIC_URL}" ]]; then
    CADDY_CONFIG="${CADDY_DIR}/Caddyfile.edge"
    MODE="edge"
else
    CADDY_CONFIG="${CADDY_DIR}/Caddyfile.lan"
    MODE="lan"
    warn "PUBLIC_URL is empty: running in lan mode (loopback Host, Origin stripped). Set PUBLIC_URL=https://dsh.example.com when a reverse proxy fronts this container"
fi

# Build the access-control rules and render the final Caddyfile from the bundled
# template (the markers are documented in docker/Caddyfile.*).
ACCESS_BLOCK=(
    "	# generated from ALLOWED_CLIENTS=${ALLOWED_CLIENTS}"
    "	handle {"
    "		@clients_denied not remote_ip ${ALLOWED_IPS[*]}"
    '		respond @clients_denied "403 Forbidden: this client is not listed in ALLOWED_CLIENTS" 403'
)
if (( ${#ALLOWED_HOSTS[@]} > 0 )); then
    ACCESS_BLOCK+=(
        "		@host_denied not host ${ALLOWED_HOSTS[*]}"
        '		respond @host_denied "403 Forbidden: this Host is not listed in ALLOWED_CLIENTS" 403'
    )
fi
# The rules must live inside a handle block. Measured behaviour of the bundled
# Caddyfiles: a bare `respond` at site level is ordered after `route`, and a
# matcher-less `route` loses to the `route /healthz` that follows it, so both
# spellings let a foreign client straight through to /healthz (200). A `handle`
# block is evaluated first, and because its handlers only fire for denied
# clients, permitted requests fall through to the real routes untouched.
ACCESS_BLOCK+=("	}")

TRUSTED_BLOCK=()
if (( ${#TRUSTED_PROXY_LIST[@]} > 0 )); then
    TRUSTED_BLOCK+=(
        "	servers {"
        "		trusted_proxies static ${TRUSTED_PROXY_LIST[*]}"
        "		client_ip_headers X-Forwarded-For X-Real-IP"
        "	}"
    )
fi

CADDY_TEMPLATE="${CADDY_CONFIG}"
CADDY_CONFIG="${CADDY_CONFIG_HOME}/Caddyfile"
if ! render_caddyfile "${CADDY_TEMPLATE}" "${CADDY_CONFIG}"; then
    fatal "could not render ${CADDY_CONFIG} from ${CADDY_TEMPLATE}"
fi
log "access control: clients ${ALLOWED_IPS[*]}${ALLOWED_HOSTS[0]:+ ; hosts ${ALLOWED_HOSTS[*]}}${TRUSTED_PROXY_LIST[0]:+ ; trusting XFF from ${TRUSTED_PROXY_LIST[*]}}"

trap shutdown_children TERM INT

# ------------------------------------------------------------------ dsh web

DSH_ARGS=(web --host 127.0.0.1 --port "${DSH_INTERNAL_PORT}" --no-open)
if [[ -n "${DSH_UPSTREAM_HOST}" ]]; then
    DSH_ARGS+=(--public-url "${PUBLIC_ORIGIN}" --trusted-host "${DSH_UPSTREAM_HOST}")
    for host in "${EXTRA_TRUSTED_HOSTS[@]}"; do
        DSH_ARGS+=(--trusted-host "${host}")
    done
fi

: > "${DSH_STARTUP_LOG}"
log "starting DeepSeek Harness ${DSH_VERSION:-unknown} on 127.0.0.1:${DSH_INTERNAL_PORT} (mode=${MODE})"
(
    cd "${DSH_WORKSPACE}"
    exec setpriv --reuid "${APP_UID}" --regid "${APP_GID}" --init-groups -- dsh "${DSH_ARGS[@]}"
) > >(tee "${DSH_STARTUP_LOG}") 2>&1 &
DSH_PID=$!

wait_for_dsh() {
    local status
    for _ in $(seq 1 60); do
        if ! kill -0 "${DSH_PID}" 2>/dev/null; then
            wait "${DSH_PID}" || true
            fatal "DeepSeek Harness exited before it became ready; see the log above"
        fi
        status="$(curl --silent --max-time 2 --output /dev/null --write-out '%{http_code}' \
            "http://127.0.0.1:${DSH_INTERNAL_PORT}/" 2>/dev/null || true)"
        [[ "${status}" =~ ^[1-4][0-9]{2}$ ]] && return 0
        sleep 1
    done
    fatal "DeepSeek Harness did not become ready within 60 seconds"
}

resolve_launch_token() {
    local line
    for _ in $(seq 1 60); do
        while IFS= read -r line; do
            if [[ "${line}" =~ ^dsh\ web:.*token=([A-Za-z0-9_.-]{16,512}) ]]; then
                DSH_LAUNCH_TOKEN="${BASH_REMATCH[1]}"
                return 0
            fi
            if [[ "${line}" == "dsh web: http://127.0.0.1:${DSH_INTERNAL_PORT}" ]]; then
                # Releases before the browser launch-token flow print the plain
                # local URL; Caddy is then a pure passthrough.
                DSH_LAUNCH_TOKEN=""
                return 0
            fi
        done < "${DSH_STARTUP_LOG}"
        kill -0 "${DSH_PID}" 2>/dev/null || fatal "DeepSeek Harness exited without publishing a launch token"
        sleep 1
    done
    printf '[entrypoint] no launch token found; last lines of the DSH startup log:\n' >&2
    tail -n 40 "${DSH_STARTUP_LOG}" >&2 || true
    fatal "DeepSeek Harness did not publish a launch token within 60 seconds"
}

wait_for_dsh
resolve_launch_token

if [[ -z "${DSH_UPSTREAM_HOST}" ]]; then
    DSH_UPSTREAM_HOST="127.0.0.1:${DSH_INTERNAL_PORT}"
fi

export PORT DSH_INTERNAL_PORT PUBLIC_URL PUBLIC_ORIGIN DSH_UPSTREAM_HOST DSH_LAUNCH_TOKEN MODE

# ------------------------------------------------------------------ caddy

as_app_user env XDG_CONFIG_HOME="${CADDY_CONFIG_HOME}" XDG_DATA_HOME="${CADDY_DATA_HOME}" \
    caddy validate --config "${CADDY_CONFIG}" --adapter caddyfile \
    || fatal "the bundled Caddy configuration failed validation: ${CADDY_CONFIG}"

log "starting Caddy on 0.0.0.0:${PORT} (auth delegated to the edge; AUTH_MODE=none)"
as_app_user env XDG_CONFIG_HOME="${CADDY_CONFIG_HOME}" XDG_DATA_HOME="${CADDY_DATA_HOME}" \
    caddy run --config "${CADDY_CONFIG}" --adapter caddyfile &
CADDY_PID=$!

set +e
wait -n "${DSH_PID}" "${CADDY_PID}"
status=$?
set -e

log "a supervised process exited with status ${status}; shutting down"
shutdown_children
wait "${DSH_PID}" 2>/dev/null || true
wait "${CADDY_PID}" 2>/dev/null || true
exit "${status}"
