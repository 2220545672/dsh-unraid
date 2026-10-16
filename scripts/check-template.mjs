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
import { dirname, resolve } from 'node:path'
import { existsSync } from 'node:fs'
import process from 'node:process'

const file = resolve(process.argv[2] ?? 'templates/dsh.xml')
const rawXml = readFileSync(file, 'utf8')

const errors = []
const warnings = []
const notes = []

/**
 * Regex matching must never see commented-out markup. A comment that merely
 * *mentions* <Profile> once made a well-intentioned search-and-replace swallow the
 * comment terminator and the root element, and every regex-based check kept
 * passing — only the strict parser in scripts/check-static.sh noticed.
 */
const stripComments = (text) => text.replace(/<!--[\s\S]*?-->/g, '')

/** Cheap structural sanity, so a mangled file fails even without python3 around. */
function assertWellFormed(text, label) {
  const opens = (text.match(/<!--/g) ?? []).length
  const closes = (text.match(/-->/g) ?? []).length
  if (opens !== closes) errors.push(`${label}: unbalanced XML comment (${opens} open, ${closes} close)`)
  if (/--(?=[^>])/.test(stripComments(text)) === false && text.includes('<!--')) {
    // a double hyphen inside a comment is illegal XML; only flag genuine comment bodies
    const bodies = [...text.matchAll(/<!--([\s\S]*?)-->/g)].map((m) => m[1])
    if (bodies.some((body) => body.includes('--'))) errors.push(`${label}: XML comment contains a double hyphen`)
  }
  const root = /^\s*(?:<\?xml[^>]*\?>\s*)?(?:<!--[\s\S]*?-->\s*)*<([A-Za-z][\w.-]*)[\s>]/.exec(text)
  if (root === null) errors.push(`${label}: no root element found (the file does not start with one)`)
  else if (!new RegExp(`</${root[1]}>\\s*$`).test(text)) {
    errors.push(`${label}: root element <${root[1]}> is never closed at the end of the file`)
  }
  return root === null ? '' : root[1]
}

const xml = stripComments(rawXml)

/**
 * Attribute quoting has to be checked textually: a straight double quote inside a
 * double-quoted attribute silently truncates it, and the file is then not
 * well-formed XML at all (measured: a Description gained one and only python's
 * parser noticed). Walk every start tag and require that its attributes are
 * exactly a sequence of name="value" pairs.
 */
function assertAttributesQuoted(text, label) {
  for (const tag of text.matchAll(/<([A-Za-z][\w.-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g)) {
    const attrs = tag[2].trim()
    if (attrs === '' || attrs === '/') continue
    const rest = attrs.replace(/([\w:.-]+)\s*=\s*"[^"]*"/g, '').trim()
    if (rest !== '' && rest !== '/') {
      errors.push(`${label}: <${tag[1]}> has a malformed attribute list (an unescaped quote?): ${rest.slice(0, 60)}`)
      break
    }
  }
}
assertAttributesQuoted(rawXml, file.replace(/^.*\//, ''))

const rootElement = assertWellFormed(rawXml, file.replace(/^.*\//, ''))
if (rootElement !== '' && !/^Container$/i.test(rootElement)) {
  errors.push(`${file.replace(/^.*\//, '')}: expected <Container> as the root element, found <${rootElement}>`)
}

const tag = (name) => {
  const match = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(xml)
  return match === null ? '' : match[1].trim()
}
/**
 * Tag-stack check for XML well-formedness. The CI gate runs the same test through
 * python3, but python3 is not installed in our own container, so a stray "<" in a
 * ReadMe text node (e.g. "http://<host>:<port>/renew") passed locally and failed
 * only in CI. This keeps the failure local, where it is cheap.
 * @param {string} source
 * @returns {string[]} problems, empty when the document is balanced
 */
function wellFormed(source) {
  const problems = []
  const stack = []
  let i = 0
  while (i < source.length) {
    const lt = source.indexOf('<', i)
    if (lt === -1) break
    if (source.startsWith('<!--', lt)) {
      const end = source.indexOf('-->', lt)
      if (end === -1) { problems.push('unterminated comment'); break }
      i = end + 3
      continue
    }
    if (source.startsWith('<?', lt)) {
      const end = source.indexOf('?>', lt)
      if (end === -1) { problems.push('unterminated processing instruction'); break }
      i = end + 2
      continue
    }
    const gt = source.indexOf('>', lt)
    if (gt === -1) { problems.push(`unterminated tag at offset ${lt}`); break }
    const tag = source.slice(lt + 1, gt)
    i = gt + 1
    if (tag.startsWith('!')) continue
    const closing = tag.startsWith('/')
    const selfClosing = tag.endsWith('/')
    const name = (closing ? tag.slice(1) : tag).split(/[\s/]/)[0]
    if (closing) {
      const open = stack.pop()
      if (open !== name) problems.push(`</${name}> closes <${open ?? 'nothing'}> (line ${source.slice(0, lt).split('\n').length})`)
      continue
    }
    if (!selfClosing) stack.push(name)
  }
  for (const open of stack) problems.push(`<${open}> is never closed`)
  return problems
}

const configs = [...xml.matchAll(/<Config\s([^>]*)>([\s\S]*?)<\/Config>/g)].map((match) => {
  const attrs = Object.fromEntries([...match[1].matchAll(/(\w+)="([^"]*)"/g)].map((a) => [a[1], a[2]]))
  return { ...attrs, value: match[2].trim() }
})
// 2 — how Unraid 7.3.2 resolves a Config, measured twice on this host:
//   * a non-empty element text is what the container gets (a Port whose text still
//     said 0.0.0.0:8080 while Default said 0.0.0.0:3082 bound 8080);
//   * an empty element text falls back to Default (a cleared Password field with
//     Default="12345678" still reached the container as 12345678).
// So an empty text is a legitimate way to ship a default, but a text that disagrees
// with Default is a trap: the file advertises one value and the container gets another.
for (const cfg of configs) {
  const text = cfg.value ?? ''
  const fallback = cfg.Default ?? ''
  if (text !== '' && text !== fallback) {
    errors.push(
      `<Config Name="${cfg.Name}">: element text ${JSON.stringify(text)} and Default ${JSON.stringify(fallback)} disagree; Unraid uses the text, so the field would show one value and create the container with another`,
    )
  }
}
// Mask only hides the value in the GUI form — the value is still stored in the
// template and still reaches the container (verified with Mask="true" and a value of
// my-own-secret-99, which arrived as DSH_PASSWORD). No assertion here, then: masking is
// a display choice. This note exists because an earlier version of this file banned it
// after a faulty check (a printf-truncated comparison) reported the variable missing.

const volumes = [...xml.matchAll(/<Volume>([\s\S]*?)<\/Volume>/g)].map((match) => ({
  host: (/<HostDir>([\s\S]*?)<\/HostDir>/.exec(match[1]) ?? [, ''])[1].trim(),
  container: (/<ContainerDir>([\s\S]*?)<\/ContainerDir>/.exec(match[1]) ?? [, ''])[1].trim(),
}))
const environmentNames = [...xml.matchAll(/<Variable>[\s\S]*?<Name>([^<]+)<\/Name>[\s\S]*?<\/Variable>/g)].map((m) => m[1].trim())

// 1 — unrendered placeholders make the file useless to CA
const placeholders = [...new Set([...xml.matchAll(/__[A-Z0-9_]+__/g)].map((m) => m[0]))]
for (const problem of wellFormed(xml)) errors.push(`${file.replace(/^.*\//, '')}: ${problem}`)

if (placeholders.length > 0) errors.push(`unrendered placeholders: ${placeholders.join(', ')}`)

// 2 — identity
const name = tag('Name')
if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) errors.push(`<Name> is missing or not container-name safe: "${name}"`)

// 3 — the image reference
const repository = tag('Repository')
if (!/^[\w.-]+(\/[\w.-]+)+(:[\w.-]+)?$/.test(repository)) errors.push(`<Repository> does not look like an image reference: "${repository}"`)
else notes.push(`image: ${repository}`)
if (repository.endsWith(':latest')) notes.push('image tag is latest (CA convention; the image repository publishes version tags too, and a user can pin one by editing the field)')

// 3b — the fields the CA docs list as minimum/recommended (Repository XML Format
//      plus the parser field catalog): without them a scan or a reviewer bounces it
const REQUIRED_TAGS = ['Name', 'Repository', 'Category', 'Icon', 'Overview', 'Project', 'Support', 'TemplateURL']
for (const tagName of REQUIRED_TAGS) {
  if (tag(tagName) === '') errors.push(`<${tagName}> is empty; the Community Apps docs list it as minimum or recommended`)
}

// 3c — ca_profile.xml is a hard submission gate: exact name, repository root, non-empty <Profile>
const profilePath = resolve(dirname(file), '..', 'ca_profile.xml')
if (existsSync(profilePath)) {
  const profile = stripComments(readFileSync(profilePath, 'utf8'))
  assertWellFormed(readFileSync(profilePath, 'utf8'), 'ca_profile.xml')
  const profileText = (/<Profile>([\s\S]*?)<\/Profile>/.exec(profile) ?? [, ''])[1].trim()
  if (profileText === '') errors.push('ca_profile.xml has an empty <Profile>; CA blocks submission finalization in that case')
  else notes.push(`ca_profile.xml: <Profile> ${profileText.length} chars`)
  for (const tagName of ['Icon', 'WebPage']) {
    if (tag(tagName) === '' && !profile.includes(`<${tagName}>`)) warnings.push(`ca_profile.xml does not set <${tagName}> (recommended)`)
  }
} else {
  notes.push('ca_profile.xml not found beside the repository root (expected when checking a rendered copy outside the repo)')
}

// 4 — links
for (const field of ['Registry', 'Project', 'Icon']) {
  const value = tag(field)
  if (!value.startsWith('https://')) errors.push(`<${field}> must be an https URL, got "${value}"`)
}
const support = tag('Support')
if (!support.startsWith('https://')) errors.push(`<Support> must be an https URL, got "${support}"`)
else if (!support.includes('forums.unraid.net')) warnings.push(`<Support> points at ${support}; Community Applications expects an Unraid forum support thread for containers you maintain yourself`)

// 5 — the sandbox flags are the whole point of this template. The reasoning lives with
//     the image now (this repository no longer carries the entrypoint or the sandbox
//     document): https://github.com/2220545672/dsh-docker/blob/main/docs/sandbox.md
const extra = tag('ExtraParams')
for (const flag of ['seccomp=unconfined', 'systempaths=unconfined']) {
  if (!extra.includes(flag)) {
    errors.push(
      `<ExtraParams> must contain --security-opt ${flag} (why: dsh-docker docs/sandbox.md — without it the agent's sandbox cannot start on Unraid)`,
    )
  }
}

// 6 — ports
const uiPort = (/\[PORT:(\d+)\]/.exec(tag('WebUI')) ?? [, ''])[1]
const portTargets = configs.filter((c) => c.Type === 'Port').map((c) => c.Target)
if (uiPort === '') errors.push('<WebUI> has no [PORT:n] placeholder')
else if (!portTargets.includes(uiPort)) errors.push(`<WebUI> publishes port ${uiPort} but no <Config Type="Port"> targets it (found: ${portTargets.join(', ') || 'none'})`)

// 7 — v2 templates describe ports, paths and variables with <Config> entries only.
//     The v1 <Data>/<Environment> blocks are still parsed by Unraid, so leaving
//     them in renders a duplicate row for every path and variable in the edit page
//     — that is how two "Container Variable: ALLOWED_CLIENTS" rows were reported.
for (const legacy of ['Data', 'Environment']) {
  if (new RegExp(`<${legacy}>`).test(rawXml)) {
    errors.push(`<${legacy}> is a v1 block; v2 templates use <Config> entries only (it duplicates every row in the Unraid UI)`)
  }
}

// 7b — if a template still carries <Data>, its volumes must agree with the Configs
const containerPaths = volumes.map((v) => v.container).sort()
const pathTargets = [...new Set(configs.filter((c) => c.Type === 'Path').map((c) => c.Target))].sort()
if (volumes.length > 0 && containerPaths.join(',') !== pathTargets.join(',')) {
  errors.push(`<Data><Volume> container dirs (${containerPaths.join(', ') || 'none'}) do not match <Config Type="Path"> targets (${pathTargets.join(', ') || 'none'})`)
}
for (const volume of volumes) {
  const config = configs.find((c) => c.Type === 'Path' && c.Target === volume.container)
  if (config === undefined) continue
  if (config.Default !== volume.host) errors.push(`${volume.container}: <Volume> host dir "${volume.host}" differs from the Config default "${config.Default}"`)
  if (!volume.host.startsWith('/mnt/user/')) errors.push(`${volume.container}: host dir should live under /mnt/user (got "${volume.host}")`)
}
// every persistent path must still be declared, whatever the template style
for (const target of pathTargets) {
  const config = configs.find((c) => c.Type === 'Path' && c.Target === target)
  if (!config.Default.startsWith('/mnt/user/')) errors.push(`${target}: Config default should live under /mnt/user (got "${config.Default}")`)
}

// 8 — variables are declared once, as <Config Type="Variable">
const variableTargets = [...new Set(configs.filter((c) => c.Type === 'Variable').map((c) => c.Target))].sort()
if (environmentNames.length > 0) {
  const envNames = [...new Set(environmentNames)].sort()
  if (variableTargets.join(',') !== envNames.join(',')) {
    warnings.push(`<Environment> variables (${envNames.join(', ') || 'none'}) differ from <Config Type="Variable"> targets (${variableTargets.join(', ') || 'none'})`)
  }
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
