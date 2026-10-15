#!/usr/bin/env node
/**
 * Compose the repository's vector icon: `icon.svg` at the repo root.
 *
 * The Community Apps starter repository ships a root `icon.svg` (its own words:
 * "a placeholder icon that the submission flow will reject if you forget to
 * replace it"), and the Builder Guide's suggested layout lists it alongside
 * README.md / LICENSE / ca_profile.xml. This script builds ours out of the two
 * upstream marks in templates/img/src/, so the file is reproducible instead of
 * hand-edited:
 *
 *   deepseek-harness  ->  the DSH whale, the main subject (transparent canvas)
 *   unraid            ->  the Unraid bars in a 1/16-area rounded badge, bottom right
 *
 * Pure string composition: no dependencies, so CI can regenerate and diff it.
 * The PNG the Docker template uses is produced by scripts/make-icon.mjs (which
 * needs sharp for rasterisation); both must stay visually in sync.
 *
 * Usage: node scripts/make-icon-svg.mjs [--out=icon.svg] [--size=256] [--badge=64]
 */
import { mkdir, readFile, writeFile } from 'node:fs/promises'
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
const out = resolve(flag('out', 'icon.svg'))
const markPath = resolve(flag('mark', 'templates/img/src/dsh-mark.svg'))
const badgePath = resolve(flag('badge-mark', 'templates/img/src/unraid-mark.svg'))

/** Pull the geometry out of an upstream mark, failing loudly if it changed shape. */
function extract(svg, { id }) {
  const viewBox = /viewBox="([^"]+)"/.exec(svg)?.[1]
  const path = /<path\b[^>]*>/.exec(svg)?.[0] ?? /<path\b[^>]*\/>/.exec(svg)?.[0]
  if (viewBox === undefined || path === undefined) {
    throw new Error(`${id}: expected a viewBox and a single <path> in the source mark`)
  }
  const [, , width, height] = viewBox.trim().split(/\s+/).map(Number)
  return { viewBox, path, width, height }
}

const mark = extract(await readFile(markPath, 'utf8'), { id: 'dsh-mark' })
const bars = extract(await readFile(badgePath, 'utf8'), { id: 'unraid-mark' })

// The Unraid mark paints with a gradient; copy the definition under a unique id
// so it cannot collide with anything the DSH mark brings along.
const gradient = /<linearGradient\b[\s\S]*?<\/linearGradient>/.exec(await readFile(badgePath, 'utf8'))?.[0]
if (gradient === undefined) throw new Error('unraid-mark: no <linearGradient> found')
const gradientNamespaced = gradient.replace(/id="a"/, 'id="unraidBars"')
const barsPath = bars.path.replace(/fill="url\(#a\)"/, 'fill="url(#unraidBars)"')

// DSH mark: contained in 94% of the canvas, centred.
const markScale = (size * 0.94) / Math.max(mark.width, mark.height)
const markOffsetX = (size - mark.width * markScale) / 2
const markOffsetY = (size - mark.height * markScale) / 2

// Unraid badge: a rounded square, 1/16 of the canvas area, inset bottom right,
// with the bars centred inside it.
const barsScale = Math.min((badge * 0.72) / bars.width, (badge * 0.72) / bars.height)
const badgeLeft = size - badge - inset
const badgeTop = size - badge - inset
const barsOffsetX = badgeLeft + (badge - bars.width * barsScale) / 2
const barsOffsetY = badgeTop + (badge - bars.height * barsScale) / 2

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" role="img" aria-label="DSH (DeepSeek Harness) for Unraid">
  <title>DSH (DeepSeek Harness) for Unraid</title>
  <!-- DSH mark: upstream templates/img/src/dsh-mark.svg (deepseek-ai/deepseek-harness, website/public/favicon.svg) -->
  <g transform="translate(${markOffsetX.toFixed(3)} ${markOffsetY.toFixed(3)}) scale(${markScale.toFixed(6)})">
    ${mark.path}
  </g>
  <defs>
    ${gradientNamespaced}
    <filter id="badgeShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="${(badge * 0.03).toFixed(2)}" stdDeviation="${(badge * 0.05).toFixed(2)}" flood-color="#0b1220" flood-opacity="0.22"/>
    </filter>
  </defs>
  <!-- Unraid badge: upstream templates/img/src/unraid-mark.svg (unraid/docs, static/img/un-mark-gradient.svg) -->
  <rect x="${badgeLeft}" y="${badgeTop}" width="${badge}" height="${badge}" rx="${radius}" ry="${radius}"
        fill="#ffffff" stroke="#d9d9e0" stroke-width="1" filter="url(#badgeShadow)"/>
  <g transform="translate(${barsOffsetX.toFixed(3)} ${barsOffsetY.toFixed(3)}) scale(${barsScale.toFixed(6)})">
    ${barsPath}
  </g>
</svg>
`

await mkdir(dirname(out), { recursive: true })
await writeFile(out, svg, 'utf8')
console.log(`${out} — ${svg.length} bytes, canvas ${size}, badge ${badge} (1/${Math.round((size * size) / (badge * badge))} of the area)`)
