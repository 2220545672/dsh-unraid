#!/usr/bin/env node
/**
 * Generate templates/img/deepseek-harness.png (256x256, RGBA) without any image
 * dependency: raw PNG chunks + zlib deflate, one rounded tile with a chevron.
 *
 * Community Applications wants a square icon reachable by URL; committing a
 * generated file keeps the repository self-contained.
 *
 * Usage: node scripts/make-icon.mjs [--out=templates/img/deepseek-harness.png] [--size=256]
 */
import { deflateSync } from 'node:zlib'
import { mkdir, writeFile } from 'node:fs/promises'
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
const out = resolve(flag('out', 'templates/img/deepseek-harness.png'))

if (!Number.isInteger(size) || size < 64 || size > 1024) {
  console.error('make-icon: --size must be an integer between 64 and 1024')
  process.exit(2)
}

const BACKGROUND_TOP = [37, 99, 235] // #2563eb
const BACKGROUND_BOTTOM = [29, 78, 216] // #1d4ed8
const INK = [255, 255, 255]
const RADIUS = size * 0.22

/** Distance from a point to a line segment, used to stroke the chevron. */
function distanceToSegment(px, py, ax, ay, bx, by) {
  const dx = bx - ax
  const dy = by - ay
  const lengthSquared = dx * dx + dy * dy
  const t = lengthSquared === 0 ? 0 : Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
  const cx = ax + t * dx
  const cy = ay + t * dy
  return Math.hypot(px - cx, py - cy)
}

function insideRoundedSquare(x, y) {
  const min = 0
  const max = size - 1
  const cx = Math.min(Math.max(x, min + RADIUS), max - RADIUS)
  const cy = Math.min(Math.max(y, min + RADIUS), max - RADIUS)
  return Math.hypot(x - cx, y - cy) <= RADIUS
}

const stroke = size * 0.055
const chevron = [
  [size * 0.36, size * 0.3, size * 0.62, size * 0.5],
  [size * 0.62, size * 0.5, size * 0.36, size * 0.7],
]
const caret = [size * 0.7, size * 0.7, stroke * 0.9]

const raw = Buffer.alloc(size * (size * 4 + 1))
for (let y = 0; y < size; y += 1) {
  const rowStart = y * (size * 4 + 1)
  raw[rowStart] = 0 // PNG filter type 0 (None)
  const mix = y / (size - 1)
  for (let x = 0; x < size; x += 1) {
    const offset = rowStart + 1 + x * 4
    const inside = insideRoundedSquare(x, y)
    let r = Math.round(BACKGROUND_TOP[0] * (1 - mix) + BACKGROUND_BOTTOM[0] * mix)
    let g = Math.round(BACKGROUND_TOP[1] * (1 - mix) + BACKGROUND_BOTTOM[1] * mix)
    let b = Math.round(BACKGROUND_TOP[2] * (1 - mix) + BACKGROUND_BOTTOM[2] * mix)
    let a = inside ? 255 : 0

    if (inside) {
      let ink = false
      for (const [ax, ay, bx, by] of chevron) {
        if (distanceToSegment(x + 0.5, y + 0.5, ax, ay, bx, by) <= stroke) ink = true
      }
      const [cx, cy, cw] = caret
      if (Math.abs(x + 0.5 - cx) <= cw / 2 && Math.abs(y + 0.5 - cy) <= stroke * 0.6) ink = true
      if (ink) {
        r = INK[0]
        g = INK[1]
        b = INK[2]
      }
    }

    raw[offset] = r
    raw[offset + 1] = g
    raw[offset + 2] = b
    raw[offset + 3] = a
  }
}

const CRC_TABLE = (() => {
  const table = new Int32Array(256)
  for (let n = 0; n < 256; n += 1) {
    let c = n
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c
  }
  return table
})()

function crc32(buffer) {
  let crc = 0xffffffff
  for (const byte of buffer) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8)
  return (crc ^ 0xffffffff) >>> 0
}

function chunk(type, data) {
  const length = Buffer.alloc(4)
  length.writeUInt32BE(data.length, 0)
  const typeAndData = Buffer.concat([Buffer.from(type, 'ascii'), data])
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(typeAndData), 0)
  return Buffer.concat([length, typeAndData, crc])
}

const header = Buffer.alloc(13)
header.writeUInt32BE(size, 0)
header.writeUInt32BE(size, 4)
header[8] = 8 // bit depth
header[9] = 6 // colour type: RGBA
header[10] = 0 // compression
header[11] = 0 // filter
header[12] = 0 // interlace

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', header),
  chunk('IDAT', deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
])

await mkdir(dirname(out), { recursive: true })
await writeFile(out, png)
process.stdout.write(`${out} (${png.length} bytes)\n`)
