#!/usr/bin/env bash
#
# Container healthcheck: Caddy must answer /healthz and DSH must answer on its
# loopback listener. Both are checked so a wedged upstream is not hidden by a
# healthy proxy (and vice versa).
set -euo pipefail

PORT="${PORT:-8080}"
DSH_INTERNAL_PORT="${DSH_INTERNAL_PORT:-3080}"

http_response() {
    local url="$1" status
    status="$(curl --silent --show-error --max-time 3 \
        --output /dev/null --write-out '%{http_code}' "${url}")" || return 1
    [[ "${status}" =~ ^[1-4][0-9]{2}$ ]]
}

http_response "http://127.0.0.1:${PORT}/healthz" || {
    printf 'healthcheck: caddy did not answer on :%s\n' "${PORT}" >&2
    exit 1
}

http_response "http://127.0.0.1:${DSH_INTERNAL_PORT}/" || {
    printf 'healthcheck: dsh did not answer on :%s\n' "${DSH_INTERNAL_PORT}" >&2
    exit 1
}
