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
#   * AUTH_MODE=builtin (the default) serves a password gate of its own, because a
#     default install must not be usable by everybody who can reach the port.
#     AUTH_MODE=none delegates authentication to an edge proxy (SWAG, Authelia,
#     ...) or to a trusted network. Anything else fails closed.
#   * DeepSeek *account* sign-in only works from a browser that can reach a
#     loopback address, which a remote browser cannot. REMOTE_SIGNIN=on (the
#     default) loads github.com/2220545672/dsh-remote-signin, which claims such an
#     address and puts the paste step into the page itself — see
#     docs/remote-signin.md. The plugin is installed from its own repository and
#     pinned by tag below; nothing of it is maintained here.

ARG NODE_VERSION=24.21.0
ARG CADDY_VERSION=2.11.7

# ---------------------------------------------------------------- runtime deps
FROM node:${NODE_VERSION}-bookworm-slim AS deps
ARG DSH_VERSION
# The remote sign-in plugin has its own repository and its own release schedule
# (github.com/2220545672/dsh-remote-signin). It is pinned to a tag on purpose: a build
# of this image must get the plugin version this Dockerfile was tested with, and the
# plugin's own CI is what validates it.
#
# The spec is spelled out as git+https, and ssh is rewritten to https for the whole
# build, because images have no keys: measured 2026-10-16, npm resolved the equivalent
# "github:2220545672/dsh-remote-signin#tag" shorthand to ssh://git@github.com and the
# build died with "Permission denied (publickey)" — while the same shorthand in a
# throwaway container that had a working ssh agent picked https and succeeded. A tag
# is a release of a public repository; nothing here should depend on a key.
ARG REMOTE_SIGNIN_VERSION=v0.2.1
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /app

RUN set -eux; \
    test -n "${DSH_VERSION}"; \
    printf '{\n  "name": "dsh-runtime",\n  "private": true,\n  "dependencies": { "@deepseek-ai/dsh": "%s", "dsh-remote-signin": "git+https://github.com/2220545672/dsh-remote-signin.git#%s" }\n}\n' "${DSH_VERSION}" "${REMOTE_SIGNIN_VERSION}" > package.json; \
    git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"; \
    npm install --omit=dev --no-audit --no-fund --loglevel=warn; \
    node -e 'const want = process.env.DSH_VERSION; const got = require("/app/node_modules/@deepseek-ai/dsh/package.json").version; if (got !== want) { console.error(`resolved ${got}, expected ${want}`); process.exit(1); }'; \
    node -e 'const p = require("/app/node_modules/dsh-remote-signin/package.json"); require("node:fs").accessSync("/app/node_modules/dsh-remote-signin/cordis.patch.yml"); console.log(`remote-signin plugin ${p.version}`);'; \
    test -f /app/node_modules/@deepseek-ai/dsh/lib/bin.js; \
    rm -rf /root/.npm

# Published npm packages carry a lot that no runtime reads: TypeScript sources and
# declarations, source maps, documentation and test fixtures.
# scripts/prune-node-modules.mjs removes exactly that, with rules instead of
# blanket extension matching, and reports what each rule cost.
#
# Deliberate properties, because this must never get in the way of a release:
#   * it never removes a package, and never asserts anything about which packages
#     upstream ships — a renamed, added or dropped dependency is a no-op here;
#   * it never touches a functional file (.js/.mjs/.wasm/assets) or a licence file;
#   * if it fails for any reason the build continues with a warning, so a bug in
#     the pruning can never block a release.
# Measured on 0.2.1-alpha.3: node_modules 834 MB -> 485 MB.
COPY scripts/prune-node-modules.mjs /tmp/prune-node-modules.mjs
RUN set -eux; \
    node /tmp/prune-node-modules.mjs --root=/app/node_modules || echo 'WARNING: dependency pruning skipped'; \
    rm -f /tmp/prune-node-modules.mjs

# ---------------------------------------------------------------------- caddy
# Downloaded from the official release rather than copied out of the caddy
# image: the asset names below are published for every stable tag
# (caddy_<version>_linux_amd64.tar.gz / _linux_arm64.tar.gz), so the path is
# evidence rather than a guess about another image's layout.
FROM debian:bookworm-slim AS caddy
ARG CADDY_VERSION
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    case "${TARGETARCH}" in \
      amd64) caddy_arch=amd64 ;; \
      arm64) caddy_arch=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/caddy.tar.gz \
      "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${caddy_arch}.tar.gz"; \
    tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy; \
    rm -f /tmp/caddy.tar.gz; \
    /usr/local/bin/caddy version

# -------------------------------------------------------------------- runtime
FROM node:${NODE_VERSION}-bookworm-slim AS runtime

ARG DSH_VERSION
ARG CADDY_VERSION
ARG DSH_REVISION=1
ARG SOURCE_REPO=dsh-unraid

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

# /home/node/workspace -> /workspace: DSH's directory picker starts at $HOME and
# lists symlinks, so this puts the projects one click from the picker's default view.
# bubblewrap  : second sandbox rung for kernels without Landlock (Unraid)
# tini        : PID 1 that reaps the DSH + Caddy pair
# git/curl/jq/ripgrep/less/procps : what an agent inside the container needs
# openssh-client : agents deployed like ours reach the host with `ssh`; shipping
#                  the client is also what makes git-over-ssh remotes work.
#                  Absent here once and the whole host workflow broke, so it is
#                  treated as a runtime requirement now.
# unzip       : archives are a normal part of the work these agents do
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bubblewrap \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        openssh-client \
        procps \
        ripgrep \
        tini \
        unzip \
        util-linux; \
    rm -rf /var/lib/apt/lists/*

COPY --from=deps /app /app
COPY --from=caddy /usr/local/bin/caddy /usr/local/bin/caddy
COPY docker/entrypoint.sh docker/healthcheck.sh /usr/local/bin/
COPY docker/Caddyfile.edge docker/Caddyfile.lan /etc/caddy/
# The patch layer that loads the remote sign-in plugin while REMOTE_SIGNIN=on. It
# names the plugin by absolute path because the launcher resolves entry names from the
# installation and the profile, and neither holds a plugin this image installs — see
# the file itself.
COPY docker/remote-signin.patch.yml /etc/dsh/remote-signin.patch.yml

RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/caddy; \
    chmod 0644 /etc/dsh/remote-signin.patch.yml; \
    printf '#!/bin/sh\nexec node /app/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"\n' > /usr/local/bin/dsh; \
    chmod 0755 /usr/local/bin/dsh; \
    npm install --global --no-audit --no-fund pnpm@10; \
    pnpm --version; \
    rm -rf /root/.npm; \
    printf 'DSH_VERSION=%s\nCADDY_VERSION=%s\n' "${DSH_VERSION}" "${CADDY_VERSION}" > /etc/dsh-version; \
    mkdir -p /data/dsh/agents /workspace; \
    chown -R 1000:1000 /data /workspace; \
    ln -sfn /workspace /home/node/workspace; \
    chown -h 1000:1000 /home/node/workspace

# HOME must point at the account the container drops to: the base image leaves it
# at /root, which uid 1000 cannot write, so `~/.ssh/config`, git config and tool
# caches all failed until this was set. The previous community image had it right;
# this one shipped without it once.
# AUTH_MODE=builtin puts the container's own password gate in front of the UI;
# DSH_PASSWORD / DSH_PASSWORD_FILE choose the password (or one is generated and
# printed once). Set AUTH_MODE=none when an authenticating proxy or a trusted
# network is in front — the entrypoint fails closed on any other value.
ENV NODE_ENV=production \
    HOME=/home/node \
    PORT=8080 \
    DSH_INTERNAL_PORT=3080 \
    DSH_HOME=/data/dsh \
    DSH_AGENTS_HOME=/data/dsh/agents \
    DSH_WORKSPACE=/workspace \
    AUTH_MODE=builtin

VOLUME ["/data", "/workspace"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
