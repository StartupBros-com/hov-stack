import type { Power } from '../types'

/**
 * Pure half of install-preflight: read the output of `claude plugin validate
 * --json` and say, in plain language, what the plugin can do. No `$` in here.
 * The raw `hooks:` and `calls:` lines stay the authority; this only explains them.
 */

export type ValidateIssue = { path?: string; message: string; code?: string }

export type ValidateSection = {
  file?: string
  type?: string
  errors: ValidateIssue[]
  warnings: ValidateIssue[]
  notes: string[]
}

export type ValidateReport = {
  success: boolean
  manifest: ValidateSection
  contents: ValidateSection[]
}

/** What the register finds by reading hooks.json and plugin.json itself. */
export type Extras = { settingsHooks: boolean; mcpServers: boolean }

export type Meta = { name: string; version: string; author: string }

export const FOOTER =
  'A list of powers, not a verdict. Read the code before you install: mods run with your permissions.'

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function issuesOf(value: unknown): ValidateIssue[] {
  if (!Array.isArray(value)) return []
  const out: ValidateIssue[] = []
  for (const one of value) {
    if (typeof one === 'string') out.push({ message: one })
    else if (isRecord(one) && typeof one.message === 'string') {
      out.push({
        message: one.message,
        path: typeof one.path === 'string' ? one.path : undefined,
        code: typeof one.code === 'string' ? one.code : undefined,
      })
    }
  }
  return out
}

function sectionOf(value: unknown): ValidateSection | null {
  if (!isRecord(value)) return null
  const notes = Array.isArray(value.notes) ? value.notes.filter((n): n is string => typeof n === 'string') : []
  return {
    file: typeof value.file === 'string' ? value.file : undefined,
    type: typeof value.type === 'string' ? value.type : undefined,
    errors: issuesOf(value.errors),
    warnings: issuesOf(value.warnings),
    notes,
  }
}

/** The report, or null when `json` is not the shape `claude plugin validate --json` prints. */
export function parseValidate(json: string): ValidateReport | null {
  let data: unknown
  try {
    data = JSON.parse(json)
  } catch {
    return null
  }
  if (!isRecord(data) || !Array.isArray(data.contents)) return null
  const manifest = sectionOf(data.manifest)
  if (!manifest) return null
  const contents: ValidateSection[] = []
  for (const one of data.contents) {
    const section = sectionOf(one)
    if (section) contents.push(section)
  }
  return { success: data.success === true, manifest, contents }
}

export type Listing = { module: string; kind: 'hooks' | 'calls'; names: string[]; line: string }

/** Split on commas that are not inside matcher braces, then drop the braces. */
function splitNames(list: string): string[] {
  const names: string[] = []
  let depth = 0
  let current = ''
  for (const ch of list) {
    if (ch === '{') depth += 1
    if (ch === '}') depth = Math.max(0, depth - 1)
    if (ch === ',' && depth === 0) {
      names.push(current)
      current = ''
    } else current += ch
  }
  names.push(current)
  return names
    .map(n => {
      const brace = n.indexOf('{')
      return (brace === -1 ? n : n.slice(0, brace)).trim()
    })
    .filter(n => n.length > 0)
}

/** Every `<module> hooks: ...` and `<module> calls: ...` note, in the order validate printed them. */
export function listingsOf(report: ValidateReport): Listing[] {
  const out: Listing[] = []
  for (const section of report.contents) {
    for (const line of section.notes) {
      for (const kind of ['hooks', 'calls'] as const) {
        const marker = ` ${kind}: `
        const at = line.indexOf(marker)
        if (at <= 0) continue
        const module = line.slice(0, at).trim()
        const names = splitNames(line.slice(at + marker.length)).map(n => (n.startsWith('$.') ? n.slice(2) : n))
        out.push({ module, kind, names, line })
        break
      }
    }
  }
  return out
}

/** The raw lines, verbatim, that the pane and the transcript print as the authority. */
export function rawLinesOf(report: ValidateReport): string[] {
  return listingsOf(report).map(l => l.line)
}

type Rule = { level: Power['level']; text: string }

const FS_READ = new Set(['fs.read', 'fs.list', 'fs.stat', 'fs.exists', 'fs.ancestors'])

function callRule(name: string): Rule {
  const family = name.split('.')[0] ?? name
  if (name === 'process.run' || name === 'process.spawn')
    return { level: 'high', text: 'Can start programs on your machine, with your permissions' }
  if (name === 'http.fetch') return { level: 'high', text: 'Can send data to and fetch from the internet' }
  if (name === 'env.get' || name === 'env.set')
    return { level: 'high', text: 'Can read your environment variables, where API keys often live' }
  if (FS_READ.has(name)) return { level: 'medium', text: 'Can read files anywhere your account can' }
  if (family === 'fs') return { level: 'high', text: 'Can create or overwrite files anywhere your account can' }
  if (name === 'model.complete' || name === 'model.fork' || name === 'model.classify')
    return { level: 'medium', text: "Can spend your plan's usage on model calls of its own" }
  if (name === 'prompt.submit') return { level: 'medium', text: 'Can start a turn as if you had typed it' }
  if (name === 'prompt.fill' || name === 'prompt.suggest' || name === 'prompt.compose')
    return { level: 'medium', text: 'Can change what goes into your prompt box' }
  if (name === 'session.send') return { level: 'medium', text: 'Can message your other sessions and subagents' }
  if (name === 'session.messages') return { level: 'medium', text: "Can read this session's whole transcript" }
  if (name === 'settings.read') return { level: 'medium', text: 'Can read your settings files' }
  if (name === 'mcp.call' || name === 'mcp.connect') return { level: 'medium', text: 'Can call MCP servers' }
  if (name === 'tool.register') return { level: 'info', text: 'Adds a tool Claude can call' }
  if (name === 'command.register') return { level: 'info', text: 'Adds a /command' }
  if (name === 'agent.register' || name === 'agent.spawn') return { level: 'medium', text: 'Can start subagents' }
  if (name === 'turn.abort') return { level: 'info', text: 'Can stop a running turn' }
  if (family === 'store') return { level: 'info', text: 'Keeps data between sessions' }
  if (family === 'state') return { level: 'info', text: 'Keeps data for the session' }
  if (name === 'ui.ask') return { level: 'info', text: 'Can ask you questions in the dialog' }
  if (family === 'ui') return { level: 'info', text: 'Draws in the interface' }
  if (family === 'audio') return { level: 'info', text: 'Plays sound' }
  if (family === 'telemetry') return { level: 'info', text: 'Logs usage records' }
  if (family === 'clock') return { level: 'info', text: 'Runs work on a timer' }
  return { level: 'info', text: `Calls $.${name}` }
}

const READS_CLAUDE = new Set([
  'prompt.submit',
  'prompt.compose',
  'prompt.section',
  'prompt.context',
  'prompt.attachment',
  'skill.prompt',
])

function hookRule(name: string): Rule {
  const family = name.split('.')[0] ?? name
  if (name === 'tool.check') return { level: 'high', text: 'Can approve or refuse tool calls before you are asked' }
  if (name === 'tool.call') return { level: 'medium', text: 'Sees every tool call and can change or refuse it' }
  if (READS_CLAUDE.has(name))
    return { level: 'medium', text: 'Can change what Claude reads: your prompts, the system prompt or reminders' }
  if (name === 'session.append') return { level: 'medium', text: 'Can rewrite what is saved in your transcript' }
  if (name === 'session.receive' || name === 'session.send')
    return { level: 'medium', text: 'Sees messages between your sessions' }
  if (name === 'agent.spawn' || name === 'agent.offer')
    return { level: 'medium', text: 'Can change which subagents run and with which model' }
  if (name === 'turn.step') return { level: 'medium', text: 'Can change which model answers each request' }
  if (name === 'plugin.register' || name === 'engine.create')
    return { level: 'high', text: 'Can refuse or alter other mods' }
  if (name === 'ui.render') return { level: 'info', text: 'Draws in the interface' }
  if (name === 'command.run') return { level: 'info', text: 'Answers a /command' }
  if (
    name === 'session.start' ||
    name === 'session.end' ||
    name === 'turn.start' ||
    name === 'turn.complete' ||
    name === 'session.measure'
  )
    return { level: 'info', text: 'Watches the session' }
  if (family === 'classic') return { level: 'info', text: 'Also reacts to settings-hook events' }
  if (family === 'fs' || family === 'process' || family === 'http' || family === 'model')
    return { level: 'high', text: 'Can see or change what other mods read, run or fetch' }
  return { level: 'info', text: `Hooks ${name}` }
}

const ORDER: Record<Power['level'], number> = { high: 0, medium: 1, info: 2 }

/** Within a level, machine access reads first: the order of the SHORT table below, unknown rows last. */
function rankOf(power: Power): number {
  const at = Object.keys(SHORT).indexOf(power.text)
  return at === -1 ? Object.keys(SHORT).length : at
}

/** Plain-language powers, duplicates merged into one row that lists every source. */
export function powersOf(report: ValidateReport, extras: Extras): Power[] {
  const byText = new Map<string, Power>()
  const add = (rule: Rule, from: string) => {
    const known = byText.get(rule.text)
    if (!known) byText.set(rule.text, { level: rule.level, text: rule.text, from: [from] })
    else if (!known.from.includes(from)) known.from.push(from)
  }
  for (const listing of listingsOf(report)) {
    for (const name of listing.names) {
      if (listing.kind === 'calls') add(callRule(name), `$.${name}`)
      else add(hookRule(name), name)
    }
  }
  if (extras.settingsHooks)
    add({ level: 'high', text: 'Runs shell commands on events (settings hooks in hooks.json)' }, 'hooks.json')
  if (extras.mcpServers) add({ level: 'medium', text: 'Starts an MCP server of its own' }, 'plugin.json')
  return [...byText.values()].sort((a, b) => ORDER[a.level] - ORDER[b.level] || rankOf(a) - rankOf(b))
}

const SHORT: Record<string, string> = {
  'Can start programs on your machine, with your permissions': 'start programs',
  'Can send data to and fetch from the internet': 'reach the internet',
  'Can read your environment variables, where API keys often live': 'read environment variables',
  'Can create or overwrite files anywhere your account can': 'create or overwrite files',
  'Can approve or refuse tool calls before you are asked': 'approve or refuse tool calls before you are asked',
  'Can refuse or alter other mods': 'refuse or alter other mods',
  'Can see or change what other mods read, run or fetch': 'see or change what other mods read, run or fetch',
  'Runs shell commands on events (settings hooks in hooks.json)': 'run shell commands on events',
}

function joinAnd(items: string[]): string {
  if (items.length <= 1) return items.join('')
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`
}

/** One sentence about the high rows. Never says "safe": no high rows is not a promise. */
export function verdictOf(powers: Power[]): string {
  const high = powers.filter(p => p.level === 'high')
  if (high.length === 0) return 'No high-risk powers found.'
  const phrases = high.map(p => SHORT[p.text] ?? p.text.replace(/^Can /, '').replace(/^./, c => c.toLowerCase()))
  return `Can ${joinAnd(phrases)}.`
}

const GLYPH: Record<Power['level'], string> = { high: '!', medium: '~', info: '-' }

export function glyphOf(level: Power['level']): string {
  return GLYPH[level]
}

/**
 * The plain-text answer for the transcript, headless runs and VS Code. The
 * first line is the verdict; a caller passes its own when validate itself
 * failed, so a failed scan is never summarised as clean.
 */
export function summaryText(meta: Meta, powers: Power[], raw: string[], verdict = verdictOf(powers)): string {
  const lines = [verdict, `${meta.name} ${meta.version} by ${meta.author}`, '']
  for (const p of powers) {
    lines.push(`${GLYPH[p.level]} ${p.text} (from: ${p.from.join(', ')})`)
  }
  if (raw.length > 0) lines.push('', ...raw)
  lines.push('', FOOTER)
  return lines.join('\n')
}
