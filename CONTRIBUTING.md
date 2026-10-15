**English** · [中文](CONTRIBUTING.zh-CN.md)

# Maintainer handbook

For maintainers of this repository and for anyone who forks it. User-facing content is in [README.md](README.md) (English, the default) and [README.zh-CN.md](README.zh-CN.md) (Chinese); the two are kept in sync, so update both whenever you change one.

## Repository layout

```
.
├── Dockerfile                 # three-stage build: DSH deps → Caddy binary → runtime
├── docker/
│   ├── entrypoint.sh          # validate env, prepare volumes, pick mode, start Caddy + DSH
│   ├── Caddyfile.edge         # PUBLIC_URL set: rewrite Host to the public authority, reject foreign Origin
│   ├── Caddyfile.lan          # PUBLIC_URL empty: pin Host to loopback, strip Origin
│   └── healthcheck.sh         # container HEALTHCHECK
├── templates/
│   ├── dsh.xml                # Unraid container template (this is the real file CA parses)
│   └── img/                   # icons: dsh.png (used by the template) + src/ (asset and generator docs)
├── icon.svg                   # repository-level vector icon (required by the CA repo layout; ca_profile.xml points at it)
├── ca_profile.xml             # CA repository info (must have a non-empty <Profile>)
├── scripts/                   # version resolution, template render/self-check, icon generation, static gates, smoke tests
├── docs/                      # user and submission docs
└── .github/workflows/         # validate (every push) + release (tracks upstream releases)
```

## Local build and self-checks

```bash
# Build (the version number comes from npm, see below)
docker build \
  --build-arg DSH_VERSION=0.2.1-alpha.3 \
  --build-arg NODE_VERSION=24.21.0 \
  --build-arg CADDY_VERSION=2.11.7 \
  -t dsh:local .

# Smoke: really starts a container and asserts /healthz, token bootstrap, cross-site 403, Caddy config, bwrap
bash scripts/smoke.sh dsh:local

# Static gates: exactly what CI runs (syntax, XML/YAML/JSON, CA layout and template bar, icon reproducibility)
bash scripts/check-static.sh
```

> `check-static.sh` needs `python3` (structural validation). When this dev machine doesn't have it, use
> `ALLOW_MISSING_PYTHON=1 bash scripts/check-static.sh` to skip that section — **skipping is not allowed in CI**; a missing python3 fails outright.

## How the upstream version is resolved

```bash
node scripts/resolve-dsh-version.mjs --json     # show the resolved result
node scripts/resolve-dsh-version.mjs --version=0.2.1-alpha.3
```

**Do not read only npm's `latest` tag.** Measured: `@deepseek-ai/dsh`'s `latest` lags behind `alpha` (2026-10-15: `latest`=`0.2.0-rc.2`, `alpha`=`0.2.1-alpha.3`), so a pipeline that reads only `latest` silently downgrades. The script enumerates every published version and takes the highest by semver; prereleases participate in the comparison per the spec.

## Icons

Two artifacts, one set of source assets — **they must be updated together**:

```bash
node scripts/make-icon-svg.mjs            # → icon.svg (pure vector, no dependencies)
node scripts/make-icon.mjs                # → templates/img/dsh.png (rasterizes icon.svg, needs sharp)
```

- `icon.svg` is the **single source of truth** for the layout; `make-icon.mjs` only rasterizes it. CI re-runs the generator and `diff`s it against what was committed, so **hand edits are not allowed**.
- Source assets and provenance are in [templates/img/src/README.md](templates/img/src/README.md). The official DSH mark uses `currentColor`; this repository pins it to black. The Unraid badge is 80px by default (256px canvas, roughly 1/10.2 of the area).
- To change colours or size: `node scripts/make-icon-svg.mjs --badge=72 --size=256`.

## Template

`templates/dsh.xml` **is not** a template source file; it is rendered output (owner/repo/tag already substituted with this repository's values). Re-render it after forking:

```bash
node scripts/render-template.mjs --owner=<your-username> --repo=dsh-unraid --tag=latest --out=templates/dsh.xml
node scripts/check-template.mjs templates/dsh.xml        # self-check a single template
```

`check-template.mjs` asserts that: CA's minimum/recommended fields are all present, `ca_profile.xml`'s `<Profile>` is non-empty, the volumes and `Config` agree on the host paths, the sandbox parameters are in place, and **comments are paired and the root element opens and closes correctly** (the regex match strips comments first, so "a tag mentioned inside a comment" cannot fool the check).

## Releasing

Two workflows:

| Workflow | Trigger | What it does |
|---|---|---|
| `validate` | Every push | Static gates + shellcheck + hadolint + `caddy validate` + script end-to-end |
| `release` | Hourly cron (:17), pushes to relevant paths, manual | Resolve version → **static gates** → build amd64 → smoke → push amd64+arm64 → tag → publish Release (with the version-pinned template and icon) |

**The gates are shared**: the verify step in `release` runs exactly the `scripts/check-static.sh` that `validate` uses, so **a commit that fails the checks publishes nothing** (the `publish` and release-asset jobs get skipped). The two used to be independent, and a red commit could still publish — that has been fixed, don't change it back.

Manual release: Actions → `release` → *Run workflow*.

| Input | Description |
|---|---|
| `version` | Empty = resolve the highest version automatically; you can also name an exact version |
| `force` | Checked = rebuild even if the `dsh-<version>` tag already exists (for re-publishing the same version, or refreshing Release assets) |

Running it again for an already-published version takes the **skip branch**: `resolve` sees the tag already exists → `build=false` → everything after that is skipped, so no build time is wasted.

## Two things to confirm for your first release

| Setting | Where | What happens if you don't change it |
|---|---|---|
| Workflow permissions = **Read and write** | Settings → Actions → General | Pushing to GHCR returns 403 (in read-only mode `packages: write` is not granted) |
| GHCR package visibility = **Public** | Your avatar → Packages → `dsh` → Package settings | An anonymous `docker pull` on Unraid returns 401 |

Also: **a public repository with no activity for 60 consecutive days gets its scheduled workflows disabled automatically**. If upstream goes quiet for a long time, open the Actions page and click *Enable workflow* once.

## Submitting to Community Applications

See [docs/ca-submission.md](docs/ca-submission.md) (the bar and the process: a public repository + an OSI license + a non-empty `<Profile>` in `ca_profile.xml` + a forum support thread + Validate/Scan under `/submit/new`). Before submitting, run `bash scripts/check-static.sh`, then self-check against [docs/ca-pitfalls.md](docs/ca-pitfalls.md) — it records real cases of delisting, deprecation, and template changes that never flowed back.

## Acceptance on a real machine (outside CI)

CI only proves the image starts and passes its assertions; **whether it really runs on the target platform** still needs a separate check (historically this step caught an edge-mode defect that CI missed). The essentials:

```bash
docker pull ghcr.io/2220545672/dsh:latest          # not logged in: confirm the package is public
docker run -d --name dsh-acceptance -p 127.0.0.1:18099:8080 \
  -e PUBLIC_URL=http://127.0.0.1:18099 -e TZ=Asia/Shanghai \
  -v /tmp/dsh-accept/data:/data -v /tmp/dsh-accept/workspace:/workspace \
  --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
  ghcr.io/2220545672/dsh:latest
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18099/healthz   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18099/          # 303 (with a dsh-auth cookie)
docker exec dsh-acceptance bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all -- /bin/sh -c 'echo SANDBOX_OK'
```

Verify with **a separate port and temporary volumes**; don't touch a running instance.
