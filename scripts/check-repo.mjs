#!/usr/bin/env node
/**
 * Repository-level check against the official Community Apps requirements.
 *
 * The docs (ca.unraid.net/submit/help → Submission Help / Builder Guide /
 * Repository XML Format / Repository Information XML) state them plainly, and
 * the Builder Guide adds: "It already includes … a placeholder icon that the
 * submission flow will reject if you forget to replace it." So this asserts both
 * halves — the required layout, and the absence of unreplaced placeholders —
 * before anything is pushed for review.
 *
 * Usage: node scripts/check-repo.mjs [--root=.]
 */
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, resolve } from 'node:path'
import process from 'node:process'

const args = process.argv.slice(2)
const flag = (name, fallback) => {
  const hit = args.find((a) => a === `--${name}` || a.startsWith(`--${name}=`))
  if (hit === undefined) return fallback
  const [, value] = hit.split('=')
  return value === undefined ? fallback : value
}

const root = resolve(flag('root', '.'))
const errors = []
const notes = []

// 1 — required root files (Submission Help + the Builder Guide's layout)
const required = ['README.md', 'LICENSE', '.gitignore', 'icon.svg', 'ca_profile.xml']
for (const file of required) {
  if (!existsSync(join(root, file))) errors.push(`missing required root file: ${file}`)
}
notes.push(`root files present: ${required.filter((f) => existsSync(join(root, f))).join(', ')}`)

// 2 — at least one template XML (Docker app and/or plugin wrapper)
const templatesDir = join(root, 'templates')
const templateFiles = existsSync(templatesDir)
  ? readdirSync(templatesDir).filter((f) => f.endsWith('.xml'))
  : []
if (templateFiles.length === 0) errors.push('no Docker template XML under templates/')
notes.push(`templates: ${templateFiles.join(', ') || '(none)'}`)

// 3 — the icon the submission flow looks for must be real artwork, not the starter's
if (existsSync(join(root, 'icon.svg'))) {
  const icon = readFileSync(join(root, 'icon.svg'), 'utf8')
  if (icon.length < 500) errors.push('icon.svg looks like a placeholder (suspiciously small)')
  if (/YOUR_GITHUB_USERNAME|placeholder/i.test(icon)) errors.push('icon.svg still contains starter placeholder text')
}

// 4 — unreplaced placeholders anywhere in the tracked tree. The starter's values
//     are what the submission flow rejects; our own __TOKEN__ style shows up in
//     the template *source* form and must have been rendered before submitting.
const P = String.raw
const placeholderPatterns = [
  [P`YOUR_GITHUB_USERNAME`, 'starter placeholder'],
  [P`YOUR_REPO_NAME`, 'starter placeholder'],
  [P`YOUR_PLUGIN_REPO`, 'starter placeholder'],
  [P`YOUR_SUPPORT_TOPIC`, 'starter placeholder'],
  [P`YOUR_DISCORD_INVITE_CODE`, 'starter placeholder'],
  [P`YOUR_REDDIT_COMMUNITY`, 'starter placeholder'],
  [P`YOUR_FACEBOOK_PAGE`, 'starter placeholder'],
  [P`example-app`, 'starter example value'],
  [P`example-plugin`, 'starter example value'],
  [P`REPLACE_WITH`, 'unfilled marker'],
  [P`__[A-Z0-9_]+__`, 'unrendered template token'],
]

let tracked = []
try {
  tracked = execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' }).trim().split('\n').filter(Boolean)
} catch {
  notes.push('git ls-files unavailable; skipping the placeholder sweep over tracked files')
}
const sweep = tracked.filter((f) => /\.(md|xml|yml|yaml|json|mjs|sh|svg)$/.test(f) && !f.startsWith('templates/img/src/'))
for (const file of sweep) {
  const text = readFileSync(join(root, file), 'utf8')
  for (const [pattern, label] of placeholderPatterns) {
    const hit = new RegExp(pattern).exec(text)
    if (hit !== null) {
      // A documented example (inside fenced code or a comment) is fine; report it
      // only when it looks live, i.e. it is not prefixed by a documentation marker.
      const line = text.slice(0, hit.index).split('\n').length
      const context = text.split('\n')[line - 1] ?? ''
      const inFence = (text.slice(0, hit.index).match(/^\s*```/gm) ?? []).length % 2 === 1
      const documented =
        inFence ||
        /^\s*(<!--|\/\/|#|\*|>|\||`|-)/.test(context) ||
        /\bexample\b|YOUR_GITHUB_USERNAME\/YOUR_REPO_NAME/i.test(context) ||
        /fork|渲染|render|placeholder|占位/i.test(context) ||
        /`[^`]*__(TOKEN|GHCR|REPO|IMAGE|DSH)[A-Z0-9_]*__[^`]*`/.test(context)
      if (!documented) errors.push(`${file}:${line} contains a ${label}: ${hit[0]}`)
    }
  }
}
notes.push(`placeholder sweep over ${sweep.length} tracked text files`)

console.log(`checked repository root: ${root}`)
for (const note of notes) console.log(`  note: ${note}`)
for (const error of errors) console.log(`  ERROR: ${error}`)
if (errors.length > 0) {
  console.error(`\n${errors.length} error(s) against the official submission requirements`)
  process.exit(1)
}
console.log('ok — layout and placeholders match the documented requirements')
