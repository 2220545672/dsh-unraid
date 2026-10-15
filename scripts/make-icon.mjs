#!/usr/bin/env node
/**
 * Rasterise the repository icon for the Docker template: templates/img/dsh.png
 *
 * `icon.svg` is the single source of truth for the artwork and its layout (built
 * by scripts/make-icon-svg.mjs from the two upstream marks), so this script
 * composes nothing itself — it renders that file. Keeping one layout means the
 * vector icon used by the Community Apps repository profile and the PNG used by
 * the container template cannot drift apart.
 *
 * sharp is deliberately not a dependency of this repository: the PNG is
 * committed, so releases never need a working image toolchain.
 *
 * Usage:
 *   node scripts/make-icon.mjs [--size=256] [--out=templates/img/dsh.png]
 *                              [--src=icon.svg] [--sharp=/path/to/sharp]
 *                              [--flatten=#rrggbb]
 *
 * --flatten renders on a solid colour instead of transparency, which is handy for
 * eyeballing how the icon reads on a light or dark Community Applications card.
 */
import { mkdir, access } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dirname, resolve } from 'node:path'
import process from 'node:process'

const args = process.argv.slice(2)
const flag = (name, fallback) => {
  const hit = args.find((a) => a === `--${name}` || a.startsWith(`--${name}=`))
  if (hit === undefined) return fallback
  const [, value] = hit.split('=')
  return value === undefined ? fallback : value
}

const size = Number(flag('size', '256'))
const out = resolve(flag('out', 'templates/img/dsh.png'))
const src = resolve(flag('src', 'icon.svg'))
const flatten = flag('flatten', '')

if (!Number.isInteger(size) || size < 64 || size > 2048) {
  console.error('make-icon: --size must be an integer between 64 and 2048')
  process.exit(2)
}

/** sharp is resolved from an explicit path, the local tree, or the DSH image. */
async function loadSharp() {
  const candidates = [flag('sharp', ''), process.env.SHARP_PATH ?? '', 'sharp', '/opt/dsh/node_modules/sharp'].filter(
    (value) => value !== '',
  )
  for (const candidate of candidates) {
    try {
      if (candidate.startsWith('/')) await access(candidate)
      return createRequire(import.meta.url)(candidate)
    } catch {
      // try the next candidate
    }
  }
  console.error(
    'make-icon: sharp is not available.\n' +
      '  Install it (pnpm add -D sharp) or point at an existing copy:\n' +
      '  node scripts/make-icon.mjs --sharp=/path/to/node_modules/sharp',
  )
  process.exit(3)
}

try {
  await access(src)
} catch {
  console.error(`make-icon: ${src} not found; run scripts/make-icon-svg.mjs first`)
  process.exit(4)
}

const sharp = await loadSharp()
await mkdir(dirname(out), { recursive: true })

// Rasterise well above the target size, then downsample: SVG strokes and the
// badge border stay crisp instead of aliasing at 256px.
const density = Math.max(384, Math.round((size * 72) / 256) * 3)
let pipeline = sharp(src, { density }).resize(size, size)
if (flatten !== '') pipeline = pipeline.flatten({ background: flatten })

const info = await pipeline.png({ compressionLevel: 9 }).toFile(out)
console.log(`${out} — ${info.width}x${info.height}, ${info.size} bytes (from ${src}${flatten ? `, flattened onto ${flatten}` : ''})`)
