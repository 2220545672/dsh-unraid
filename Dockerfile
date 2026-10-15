# syntax=docker/dockerfile:1.7
#
# DeepSeek Harness — Unraid-friendly image.
#
# Why this image exists (and how it differs from other community builds):
#   * Unraid kernels ship WITHOUT Landlock (CONFIG_SECURITY_LANDLOCK is off in
#     6.18.x-Unraid). DSH's bash tool sandbox therefore needs its second rung,
#     bubblewrap, which is installed here. See docs/unraid-sandbox.md.
#   * The upstream version is resolved from the npm registry (highest semver
#     across every dist-tag), never from the `latest` tag alone — see
#     scripts/resolve-dsh-version.mjs.
#   * No built-in password auth: this image expects an edge proxy (SWAG,
#     Authelia, ...) or a trusted LAN. AUTH_MODE other than `none` fails closed.

ARG NODE_VERSION=24.21.0
ARG CADDY_VERSION=2.11.7

# ---------------------------------------------------------------- runtime deps
FROM node:${NODE_VERSION}-bookworm-slim AS deps
ARG DSH_VERSION
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /app

RUN set -eux; \
    test -n "${DSH_VERSION}"; \
    printf '{\n  "name": "deepseek-harness-runtime",\n  "private": true,\n  "dependencies": { "@deepseek-ai/dsh": "%s" }\n}\n' "${DSH_VERSION}" > package.json; \
    npm install --omit=dev --no-audit --no-fund --loglevel=warn; \
    node -e 'const want = process.env.DSH_VERSION; const got = require("/app/node_modules/@deepseek-ai/dsh/package.json").version; if (got !== want) { console.error(`resolved ${got}, expected ${want}`); process.exit(1); }'; \
    test -f /app/node_modules/@deepseek-ai/dsh/lib/bin.js; \
    rm -rf /root/.npm

# ---------------------------------------------------------------------- caddy
FROM caddy:${CADDY_VERSION}-alpine AS caddy

# -------------------------------------------------------------------- runtime
FROM node:${NODE_VERSION}-bookworm-slim AS runtime

ARG DSH_VERSION
ARG CADDY_VERSION
ARG DSH_REVISION=1
ARG SOURCE_REPO=deepseek-harness-unraid

LABEL org.opencontainers.image.title="DeepSeek Harness" \
      org.opencontainers.image.description="DeepSeek Harness web UI with a working bubblewrap sandbox on Landlock-less hosts (Unraid)" \
      org.opencontainers.image.version="${DSH_VERSION}" \
      org.opencontainers.image.revision="${DSH_REVISION}" \
      org.opencontainers.image.source="https://github.com/${SOURCE_REPO}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/node:${NODE_VERSION}-bookworm-slim" \
      io.dsh.upstream.package="@deepseek-ai/dsh" \
      io.dsh.upstream.version="${DSH_VERSION}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# bubblewrap  : second sandbox rung for kernels without Landlock (Unraid)
# tini        : PID 1 that reaps the DSH + Caddy pair
# git/curl/jq/ripgrep/less/procps : what an agent inside the container needs
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bubblewrap \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        procps \
        ripgrep \
        tini \
        util-linux; \
    rm -rf /var/lib/apt/lists/*

COPY --from=deps /app /app
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY docker/entrypoint.sh docker/healthcheck.sh /usr/local/bin/
COPY docker/Caddyfile.edge docker/Caddyfile.lan /etc/caddy/

RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/caddy; \
    printf '#!/bin/sh\nexec node /app/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"\n' > /usr/local/bin/dsh; \
    chmod 0755 /usr/local/bin/dsh; \
    printf 'DSH_VERSION=%s\nCADDY_VERSION=%s\n' "${DSH_VERSION}" "${CADDY_VERSION}" > /etc/deepseek-harness-version; \
    mkdir -p /data/dsh/agents /workspace; \
    chown -R 1000:1000 /data /workspace

ENV NODE_ENV=production \
    PORT=8080 \
    DSH_INTERNAL_PORT=3080 \
    DSH_HOME=/data/dsh \
    DSH_AGENTS_HOME=/data/dsh/agents \
    DSH_WORKSPACE=/workspace \
    AUTH_MODE=none

VOLUME ["/data", "/workspace"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
