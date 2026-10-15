#!/usr/bin/env node
/**
 * Compose the Unraid app icon: the DSH mark as the main subject, with a small
 * Unraid badge in the bottom-right corner.
 *
 * Layout (defaults, in a 256x256 canvas):
 *   - DSH mark (blue whale) contained in 94% of the canvas, centred, transparent
 *     background so the icon works on any Community Applications card colour.
 *   - Unraid badge: a 64x64 rounded square — 1/16 of the canvas *area* — inset
 *     10px from the bottom-right corner, radius 14px, white tile with a hairline
 *     border and a soft drop shadow.
 *
 * Sources live in templates/img/src/ (see the README there for provenance and
 * the trademark note). Rasterisation needs sharp, which is deliberately NOT a
 * dependency of this repository: the generated PNG is committed, so the icon
 * does not depend on a working toolchain at release time.
 *
 * Usage:
 *   node scripts/make-icon.mjs [--size=256] [--out=templates/img/dsh.png]
 *                              [--badge=64] [--inset=10] [--radius=14]
 *                              [--sharp=/path/to/sharp] [--flatten=#rrggbb]
 *
 * --flatten renders the icon on a solid colour instead of transparency, which is
 * handy for eyeballing how it reads on a light or dark card.
 */
import { mkdir, writeFile, access } from 'node:fs/promises'
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
const badge = Number(flag('badge', String(Math.round(size / 4))))
const inset = Number(flag('inset', String(Math.round(size * 0.039))))
const radius = Number(flag('radius', String(Math.round(badge * 0.22))))
const out = resolve(flag('out', 'templates/img/dsh.png'))
const markSrc = resolve(flag('mark', 'templates/img/src/dsh-mark.svg'))
const badgeSrc = resolve(flag('badge-mark', 'templates/img/src/unraid-mark.svg'))
const flatten = flag('flatten', '')

for (const [name, value] of [['size', size], ['badge', badge], ['inset', inset], ['radius', radius]]) {
  if (!Number.isFinite(value) || value <= 0) {
    console.error(`make-icon: --${name} must be a positive number`)
    process.exit(2)
  }
}
if (badge * 2 + inset > size) {
  console.error('make-icon: the badge does not fit in the canvas')
  process.exit(2)
}

/** sharp is resolved from an explicit path, the local tree, or the DSH image. */
async function loadSharp() {
  const candidates = [
    flag('sharp', ''),
    process.env.SHARP_PATH ?? '',
    'sharp',
    '/opt/dsh/node_modules/sharp',
  ].filter((value) => value !== '')

  for (const candidate of candidates) {
    try {
      if (candidate.startsWith('/')) await access(candidate)
      const require = createRequire(import.meta.url)
      return require(candidate)
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

const sharp = await loadSharp()

for (const [label, path] of [['mark', markSrc], ['badge mark', badgeSrc]]) {
  try {
    await access(path)
  } catch {
    console.error(`make-icon: ${label} source not found: ${path}`)
    process.exit(4)
  }
}

// 1 — the main subject
const markSize = Math.round(size * 0.94)
const mark = await sharp(markSrc, { density: 1200 })
  .resize(markSize, markSize, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
  .png()
  .toBuffer()

// 2 — the badge tile: rounded square, hairline border, soft shadow underneath
const tileSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="${badge}" height="${badge}">
  <rect x="0.5" y="0.5" width="${badge - 1}" height="${badge - 1}" rx="${radius}" ry="${radius}" fill="#ffffff" stroke="#d9d9e0" stroke-width="1"/>
</svg>`
const shadowSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="${badge}" height="${badge}">
  <rect x="0" y="0" width="${badge}" height="${badge}" rx="${radius}" ry="${radius}" fill="#0b1220" fill-opacity="0.22"/>
</svg>`
const tile = await sharp(Buffer.from(tileSvg)).png().toBuffer()
const shadow = await sharp(Buffer.from(shadowSvg))
  .blur(Math.max(1, badge * 0.05))
  .png()
  .toBuffer()

const barsSize = Math.round(badge * 0.72)
const bars = await sharp(badgeSrc, { density: 900 })
  .resize(barsSize, barsSize, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
  .png()
  .toBuffer()

const badgeLayer = await sharp(tile)
  .composite([{ input: bars, gravity: 'center' }])
  .png()
  .toBuffer()

const badgeLeft = size - badge - inset
const badgeTop = size - badge - inset

// 3 — compose
await mkdir(dirname(out), { recursive: true })

let canvas = sharp({
  create: { width: size, height: size, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
}).composite([
  { input: mark, gravity: 'center' },
  { input: shadow, top: badgeTop + Math.max(1, Math.round(badge * 0.03)), left: badgeLeft + Math.max(1, Math.round(badge * 0.02)) },
  { input: badgeLayer, top: badgeTop, left: badgeLeft },
])

if (flatten !== '') canvas = canvas.flatten({ background: flatten })

const info = await canvas.png({ compressionLevel: 9 }).toFile(out)

console.log(`${out} — ${info.width}x${info.height}, ${info.size} bytes, badge ${badge}px (1/${Math.round((size * size) / (badge * badge))} of the area)`)
