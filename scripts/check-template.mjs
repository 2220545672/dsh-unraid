#!/usr/bin/env node
/**
 * Structural self-check for the Unraid template. Community Applications reads
 * these fields and a mismatch is the kind of bug that only shows up on someone
 * else's server (a volume that writes into the container, a WebUI port that opens
 * the wrong thing, an image tag nobody can pull), so assert them here.
 *
 * Usage: node scripts/check-template.mjs [templates/dsh.xml]
 *
 * Exits non-zero on errors; warnings do not fail the run.
 */
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import process from 'node:process'

const file = resolve(process.argv[2] ?? 'templates/dsh.xml')
const xml = readFileSync(file, 'utf8')

const errors = []
const warnings = []
const notes = []

const tag = (name) => {
  const match = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(xml)
  return match === null ? '' : match[1].trim()
}
const configs = [...xml.matchAll(/<Config\s([^>]*)>([\s\S]*?)<\/Config>/g)].map((match) => {
  const attrs = Object.fromEntries([...match[1].matchAll(/(\w+)="([^"]*)"/g)].map((a) => [a[1], a[2]]))
  return { ...attrs, value: match[2].trim() }
})
const volumes = [...xml.matchAll(/<Volume>([\s\S]*?)<\/Volume>/g)].map((match) => ({
  host: (/<HostDir>([\s\S]*?)<\/HostDir>/.exec(match[1]) ?? [, ''])[1].trim(),
  container: (/<ContainerDir>([\s\S]*?)<\/ContainerDir>/.exec(match[1]) ?? [, ''])[1].trim(),
}))
const environmentNames = [...xml.matchAll(/<Variable>[\s\S]*?<Name>([^<]+)<\/Name>[\s\S]*?<\/Variable>/g)].map((m) => m[1].trim())

// 1 — unrendered placeholders make the file useless to CA
const placeholders = [...new Set([...xml.matchAll(/__[A-Z0-9_]+__/g)].map((m) => m[0]))]
if (placeholders.length > 0) errors.push(`unrendered placeholders: ${placeholders.join(', ')}`)

// 2 — identity
const name = tag('Name')
if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) errors.push(`<Name> is missing or not container-name safe: "${name}"`)

// 3 — the image reference
const repository = tag('Repository')
if (!/^[\w.-]+(\/[\w.-]+)+(:[\w.-]+)?$/.test(repository)) errors.push(`<Repository> does not look like an image reference: "${repository}"`)
else notes.push(`image: ${repository}`)
if (/:(latest)?$/.test(repository)) notes.push('image tag is latest (CA convention; the release workflow also ships version-pinned templates)')

// 4 — links
for (const field of ['Registry', 'Project', 'Icon']) {
  const value = tag(field)
  if (!value.startsWith('https://')) errors.push(`<${field}> must be an https URL, got "${value}"`)
}
const support = tag('Support')
if (!support.startsWith('https://')) errors.push(`<Support> must be an https URL, got "${support}"`)
else if (!support.includes('forums.unraid.net')) warnings.push(`<Support> points at ${support}; Community Applications expects an Unraid forum support thread for containers you maintain yourself`)

// 5 — the sandbox flags are the whole point of this template
const extra = tag('ExtraParams')
for (const flag of ['seccomp=unconfined', 'systempaths=unconfined']) {
  if (!extra.includes(flag)) errors.push(`<ExtraParams> must contain --security-opt ${flag} (see docs/unraid-sandbox.md)`)
}

// 6 — ports
const uiPort = (/\[PORT:(\d+)\]/.exec(tag('WebUI')) ?? [, ''])[1]
const portTargets = configs.filter((c) => c.Type === 'Port').map((c) => c.Target)
if (uiPort === '') errors.push('<WebUI> has no [PORT:n] placeholder')
else if (!portTargets.includes(uiPort)) errors.push(`<WebUI> publishes port ${uiPort} but no <Config Type="Port"> targets it (found: ${portTargets.join(', ') || 'none'})`)

// 7 — volumes and paths must agree
const containerPaths = volumes.map((v) => v.container).sort()
const pathTargets = [...new Set(configs.filter((c) => c.Type === 'Path').map((c) => c.Target))].sort()
if (containerPaths.join(',') !== pathTargets.join(',')) {
  errors.push(`<Data><Volume> container dirs (${containerPaths.join(', ') || 'none'}) do not match <Config Type="Path"> targets (${pathTargets.join(', ') || 'none'})`)
}
for (const volume of volumes) {
  const config = configs.find((c) => c.Type === 'Path' && c.Target === volume.container)
  if (config === undefined) continue
  if (config.Default !== volume.host) errors.push(`${volume.container}: <Volume> host dir "${volume.host}" differs from the Config default "${config.Default}"`)
  if (!volume.host.startsWith('/mnt/user/')) errors.push(`${volume.container}: host dir should live under /mnt/user (got "${volume.host}")`)
}

// 8 — variables must be declared in both places, or Unraid's GUI and the runtime disagree
const variableTargets = [...new Set(configs.filter((c) => c.Type === 'Variable').map((c) => c.Target))].sort()
const envNames = [...new Set(environmentNames)].sort()
if (variableTargets.join(',') !== envNames.join(',')) {
  warnings.push(`<Environment> variables (${envNames.join(', ') || 'none'}) differ from <Config Type="Variable"> targets (${variableTargets.join(', ') || 'none'})`)
}

// 9 — a container that needs --privileged is a red flag for review
if (tag('Privileged') !== 'false') warnings.push('<Privileged> is not false')

// 10 — this image authenticates at the edge, so PUBLIC_URL must be offered
if (!variableTargets.includes('PUBLIC_URL')) warnings.push('<Config> does not expose PUBLIC_URL; edge deployments need it for the strict Origin mode')

console.log(`checked ${file}`)
for (const note of notes) console.log(`  note: ${note}`)
for (const warning of warnings) console.log(`  warn: ${warning}`)
for (const error of errors) console.log(`  ERROR: ${error}`)
if (errors.length > 0) {
  console.error(`\n${errors.length} error(s)`)
  process.exit(1)
}
console.log(`ok — ${configs.length} config entries, ${volumes.length} volumes, ${warnings.length} warning(s)`)
