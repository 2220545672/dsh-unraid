#!/usr/bin/env node
/**
 * Strip what no runtime needs out of a production `node_modules` tree.
 *
 * Published npm packages carry build-time material that inflates an image for
 * nothing: TypeScript sources and declarations, source maps, documentation and
 * test fixtures. Measured on @deepseek-ai/dsh 0.2.1-alpha.3, that was ~270 MB of
 * an 834 MB tree (plus 146 MB of optional LibreOffice wasm assets).
 *
 * No package is ever removed, only build-time files inside packages: DeepSeek's
 * own packages keep every functional file (their .js/.mjs/.wasm/assets and their
 * licence files are untouched), and an earlier attempt to drop a whole official
 * package — @deepseek-ai/libreoffice-kit-wasm — was rejected and reverted.
 *
 * The `.ts` rule is deliberately conservative, because deleting the wrong file
 * would break a package at runtime:
 *   * a package that has no compiled JavaScript at all is left alone, and
 *   * a package whose entry points (main / module / bin / exports / types) point
 *     at a `.ts` file is left alone.
 * Only then are TypeScript sources removed.
 *
 * Licence files (LICENSE, COPYING, NOTICE, AUTHORS — with or without an
 * extension) are never touched: MIT/BSD require them to travel with the code.
 *
 * Usage: node scripts/prune-node-modules.mjs [--root=/app/node_modules]
 *                                            [--dry-run]
 */
import { readFileSync, readdirSync, rmSync, statSync } from 'node:fs'
import { join } from 'node:path'
import process from 'node:process'

const args = process.argv.slice(2)
const hasFlag = (name) => args.includes(`--${name}`)
const flag = (name, fallback) => {
  const withEquals = args.find((a) => a.startsWith(`--${name}=`))
  if (withEquals !== undefined) return withEquals.slice(name.length + 3)
  const index = args.indexOf(`--${name}`)
  return index !== -1 && args[index + 1] !== undefined ? args[index + 1] : fallback
}

const root = flag('root', '/app/node_modules')
const dryRun = hasFlag('dry-run')

/**
 * A package is never removed — only build-time files inside packages. DeepSeek's
 * own packages keep every functional file (.js/.mjs/.wasm/assets) and every
 * licence file; an earlier attempt to drop a whole official package
 * (@deepseek-ai/libreoffice-kit-wasm) was rejected and reverted, and the build
 * now asserts that package is still present.
 */

const LICENCE = /^(licen[cs]e|copying|notice|authors|contributors)(\..*)?$/i
const DOC = /\.(md|markdown)$/i
const DECLARATION = /\.d\.(ts|mts|cts)$/i
const SOURCE = /\.(ts|mts|cts)$/i
const COMPILED = /\.(js|cjs|mjs)$/
const JUNK_FILE = /(\.tsbuildinfo|\.tgz)$|^\.(eslintrc|prettierrc)|^tsconfig.*\.json$/i
const JUNK_DIR = /^(test|tests|__tests__|__mocks__|example|examples|\.github|\.vscode)$/


const removed = new Map()
const note = (rule, bytes, files = 1) => {
  const entry = removed.get(rule) ?? { bytes: 0, files: 0 }
  entry.bytes += bytes
  entry.files += files
  removed.set(rule, entry)
}
const drop = (path, rule) => {
  let size = 0
  try {
    const stat = statSync(path)
    size = stat.isDirectory() ? directorySize(path) : stat.size
  } catch {
    return
  }
  note(rule, size)
  if (!dryRun) rmSync(path, { recursive: true, force: true })
}

function directorySize(path) {
  let total = 0
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const child = join(path, entry.name)
    if (entry.isDirectory()) total += directorySize(child)
    else if (entry.isFile()) total += statSync(child).size
  }
  return total
}

/** Every package directory inside a node_modules tree (including nested ones). */
function findPackages(dir, found = []) {
  let entries
  try {
    entries = readdirSync(dir, { withFileTypes: true })
  } catch {
    return found
  }
  if (entries.some((entry) => entry.isFile() && entry.name === 'package.json')) found.push(dir)
  for (const entry of entries) {
    if (!entry.isDirectory()) continue
    findPackages(join(dir, entry.name), found)
  }
  return found
}

function entryPointsUseTypeScript(pkgDir) {
  let pkg
  try {
    pkg = JSON.parse(readFileSync(join(pkgDir, 'package.json'), 'utf8'))
  } catch {
    return true // unreadable manifest: leave the package untouched
  }

  const isSource = (value) => typeof value === 'string' && /\.(?:ts|mts|cts)$/i.test(value) && !/\.d\.(?:ts|mts|cts)$/i.test(value)
  // Runtime entry points: these must never resolve to TypeScript.
  if ([pkg.main, pkg.module, pkg.bin].some((field) => JSON.stringify(field ?? '').includes('.ts') && isSource(typeof field === 'string' ? field : undefined))) return true
  if ([pkg.main, pkg.module].some(isSource)) return true

  // Inside "exports", a .ts path only matters when it is reachable at runtime:
  // values under "types"/"typings" are declarations, and custom conditions
  // (keys starting with "@", such as zod's "@zod/source") are opt-in tooling.
  const walkExports = (node, key) => {
    if (typeof node === 'string') return isSource(node) && key !== 'types' && key !== 'typings' && !key.startsWith('@')
    if (node === null || typeof node !== 'object') return false
    return Object.entries(node).some(([childKey, child]) => walkExports(child, childKey))
  }
  return walkExports(pkg.exports, '')
}

function walkFiles(dir, visit) {
  let entries
  try {
    entries = readdirSync(dir, { withFileTypes: true })
  } catch {
    return
  }
  for (const entry of entries) {
    const child = join(dir, entry.name)
    if (entry.isDirectory()) {
      if (JUNK_DIR.test(entry.name)) drop(child, `directory ${entry.name}/`)
      else if (child !== dir && packageDirs.has(child)) continue // its own iteration handles it
      else walkFiles(child, visit)
    } else if (entry.isFile()) {
      visit(child, entry.name)
    }
  }
}

const packageDirs = new Set(findPackages(root))
const packages = [root, ...packageDirs]
let strippedSources = 0

for (const pkgDir of packages) {
  const pristine = entryPointsUseTypeScript(pkgDir)
  let hasCompiled = false
  walkFiles(pkgDir, (file, name) => {
    if (LICENCE.test(name)) return
    if (COMPILED.test(name)) hasCompiled = true
  })
  walkFiles(pkgDir, (file, name) => {
    if (LICENCE.test(name)) return
    if (DECLARATION.test(name)) return drop(file, 'declarations (.d.ts)')
    if (/\.map$/i.test(name)) return drop(file, 'source maps')
    if (JUNK_FILE.test(name)) return drop(file, 'build config')
    if (DOC.test(name)) return drop(file, 'documentation')
    if (!SOURCE.test(name)) return
    // TypeScript source: only safe when the package actually ships compiled
    // JavaScript and none of its entry points resolve to a .ts file.
    if (pristine || !hasCompiled) return
    strippedSources += 1
    drop(file, 'TypeScript sources')
  })
}

const mib = (bytes) => `${(bytes / 1048576).toFixed(1)} MB`
try {
  console.log(`prune-node-modules: ${root}${dryRun ? ' (dry run)' : ''}`)
  for (const [rule, entry] of [...removed].sort((a, b) => b[1].bytes - a[1].bytes)) {
    console.log(`  ${rule.padEnd(28)} ${mib(entry.bytes).padStart(9)}  ${entry.files} item(s)`)
  }
  const total = [...removed.values()].reduce((sum, entry) => sum + entry.bytes, 0)
  console.log(`  ${'total'.padEnd(28)} ${mib(total).padStart(9)}  (${strippedSources} .ts removed only where compiled output exists)`)
  console.log(`  root is now ${mib(directorySize(root))}`)
} catch (error) {
  // Never fail a build because of this script: report and leave the tree as is.
  console.error('prune-node-modules: skipped after an unexpected error:', error?.message ?? error)
}
