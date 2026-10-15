**English** · [中文](publish.zh-CN.md)

# Publishing to GitHub and getting the first release through

For people who fork this repository (it also serves as the maintainer's runbook). The whole chain is: **GitHub repository → GitHub Actions build → GHCR image → version-pinned template in the Release → Community Applications**.

## 1. Create the repository and push

Create a **public** repository (CA requires public readability, and the icon URL must be a public address too); `dsh-unraid` is the suggested name. Do **not** tick "Add a README" (the commit history already exists locally):

```bash
git remote add origin git@github.com:<your-username>/dsh-unraid.git   # or https://github.com/<your-username>/dsh-unraid.git
git push -u origin main
```

## 2. Two repository settings you must confirm

| Setting | Where | What happens if you leave it |
|---|---|---|
| **Workflow permissions = Read and write** | Settings → Actions → General → Workflow permissions | New repositories default to read-only. While read-only, even a `packages: write` in the workflow is **not** granted, and pushing to GHCR returns 403 outright. |
| **GHCR package visibility = Public** | After the first successful release: your avatar → Packages → `dsh` → Package settings → Change visibility | A GHCR package tied to a public repository is usually public automatically; if it is still private, an anonymous `docker pull` on Unraid returns 401. |

Two more GitHub behaviours are worth knowing:

- **A public repository with 60 consecutive days of no activity has its scheduled workflows disabled automatically.** This repository checks upstream every hour, so as long as upstream keeps releasing this will not trigger; if upstream goes quiet for a long time, open the Actions page and click *Enable workflow* once.
- Workflows are grouped by `concurrency`: a new release run on the same branch cancels the older **queued** run outright, so several builds never race to publish at once.

## 3. The first release

The push itself triggers `release` (the `push` `paths` cover `Dockerfile` / `docker/**` / `scripts/**` / the workflow itself). You can also do it manually: Actions → **release** → *Run workflow*.

| Input | Description |
|---|---|
| `version` | Empty = resolve the **highest semver** of `@deepseek-ai/dsh` on npm automatically (alpha/rc included) |
| `force` | Ticked = rebuild even if the `dsh-<version>` tag already exists (for re-releasing the same version) |

Flow: resolve the version → build amd64 → **smoke test** (nothing is pushed if it fails) → build and push amd64+arm64 (`:version`, `:latest`, `:alpha|rc|stable`) → create the `dsh-<version>` tag → publish the Release (with the **version-pinned** template XML and icon).

Troubleshooting entry points:

- `verify` fails = the image did not start or a smoke assertion failed; the log carries the container logs along (`/healthz`, token bootstrap, cross-site 403, the two Caddyfiles, `bwrap`).
- `publish` fails = usually the Workflow permissions from step 2 were not opened up.
- `publish release and template` fails = permissions (`contents: write`) or a missing `gh`; that job does a **clobber update** on an existing Release, so re-releasing the same version does not error.

## 4. Point the template at your namespace

`templates/dsh.xml` in the repository keeps the `__GHCR_OWNER__` / `__REPO__` / `__IMAGE_TAG__` placeholders, which avoids hardcoding and makes forking easier; but **CA parses the concrete file in the repository**, so render it once and commit that before submitting to CA (this repository is currently rendered for `2220545672`):

```bash
node scripts/render-template.mjs --owner=<your-username> --repo=dsh-unraid --tag=latest --out=templates/dsh.xml
node scripts/check-template.mjs templates/dsh.xml     # self-check before committing
git add templates/dsh.xml && git commit -m "chore: render template for <owner>" && git push
```

The icon is already committed at `templates/img/dsh.png`. Changing its style requires installing `sharp` first:

```bash
pnpm add -D sharp && node scripts/make-icon.mjs --out=templates/img/dsh.png
node scripts/make-icon.mjs --flatten='#f4f4f6' --out=/tmp/preview-light.png   # see how it looks on a light card
```

Sources and the trademark note are in `templates/img/src/README.md`.

## 5. CA is the last step

Only once the image, the template and automatic version tracking all work does Community Applications come into play: see [ca-submission.md](ca-submission.md) (hard requirements, the Validate/Scan flow) and [ca-pitfalls.md](ca-pitfalls.md) (real cases that get delisted or deprecated).
