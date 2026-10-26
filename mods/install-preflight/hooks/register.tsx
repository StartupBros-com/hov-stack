import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Report } from '../types'
import { FOOTER, glyphOf, parseValidate, powersOf, rawLinesOf, summaryText, verdictOf } from './explain'

/**
 * install-preflight: /preflight <folder | owner/repo | git url>.
 *
 * Runs `claude plugin validate --json` on the target, turns the hooks: and
 * calls: lines into a plain list of powers, and shows it in a pane and as the
 * command's answer. It lists powers, it never judges: you stay in control.
 */

const PANE = 'preflight'
const report = atom({ plugin: 'install-preflight', key: 'report' } as const, null as Report | null)

const USAGE =
  'Preflight shows, in plain language, what a plugin or mod can do before you install it. ' +
  'Give it a local folder (/preflight ./my-plugin), a GitHub repo (/preflight owner/repo) or a git url ' +
  '(/preflight https://github.com/owner/repo.git). It runs claude plugin validate and lists the powers ' +
  'it finds, with the raw hooks: and calls: lines underneath. Nothing is installed.'

const REPO_FORM = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/

function firstLine(text: string): string {
  return (text.split('\n').find(line => line.trim().length > 0) ?? '').trim()
}

function baseName(dir: string): string {
  const parts = dir.split('/').filter(Boolean)
  return parts[parts.length - 1] ?? dir
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

/** FNV-1a of the url, so two urls that differ only in punctuation never share a clone directory. */
function fnv1a(text: string): string {
  let h = 0x811c9dc5
  for (let i = 0; i < text.length; i += 1) h = Math.imul(h ^ text.charCodeAt(i), 0x01000193) >>> 0
  return h.toString(16).padStart(8, '0')
}

/** Where a repository url is cloned for preflight: a readable tail of the url plus a digest of all of it. */
export function cloneDirOf(url: string): string {
  const tail = url.replace(/[^A-Za-z0-9_-]/g, '_').slice(-48)
  return `/tmp/install-preflight/${tail}-${fnv1a(url)}`
}

/**
 * Moves an existing shallow clone of `url` to the remote's current head; false
 * when the clone is of another repository or either step fails.
 */
async function refreshClone($: EngineInterface, dir: string, url: string): Promise<boolean> {
  try {
    const origin = await $.process.run(['git', '-C', dir, 'remote', 'get-url', 'origin'], { timeoutMs: 10000 })
    if (origin.exitCode !== 0 || origin.stdout.trim() !== url) return false
    const fetched = await $.process.run(['git', '-C', dir, 'fetch', '--depth', '1', '--quiet', 'origin'], {
      timeoutMs: 60000,
    })
    if (fetched.exitCode !== 0) return false
    const reset = await $.process.run(['git', '-C', dir, 'reset', '--hard', '--quiet', 'FETCH_HEAD'], {
      timeoutMs: 30000,
    })
    return reset.exitCode === 0
  } catch {
    return false
  }
}

function authorOf(value: unknown): string {
  if (typeof value === 'string' && value.trim()) return value.trim()
  if (isRecord(value) && typeof value.name === 'string' && value.name.trim()) return value.name.trim()
  return 'unknown author'
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    try {
      await $.command.register({
        name: 'preflight',
        description: 'Show what a plugin or mod can do before you install it',
        argumentHint: '<folder | owner/repo | git url>',
      })
    } catch {
      // the name is taken; /preflight is simply not offered
    }
    return next(e)
  })

  on('command.run', { command: 'preflight' }, async ($, e) => {
    const arg = e.args.trim()
    if (!arg) return { text: USAGE }

    let dir = arg
    let source: Report['source'] = 'folder'
    let url: string | null = null
    let note = ''

    if (!(await $.fs.exists(arg))) {
      if (REPO_FORM.test(arg)) url = `https://github.com/${arg}.git`
      else if (/^(https?:\/\/|git@)/.test(arg)) url = arg
      else return { text: `Could not find ${arg}. ${USAGE}` }

      source = 'repo'
      dir = cloneDirOf(url)
      let needsClone = true
      if (await $.fs.exists(dir)) {
        // A clone from an earlier run may be stale, half-written, or of another repository: bring it
        // to the current head, and when that fails leave it alone and clone afresh beside it.
        if (await refreshClone($, dir, url)) {
          note = 'Refreshed the clone fetched earlier.\n\n'
          needsClone = false
        } else {
          dir = `${dir}-${await $.clock.now()}`
        }
      }
      if (needsClone) {
        try {
          const cloned = await $.process.run(
            ['git', 'clone', '--depth', '1', '--quiet', url, dir],
            { timeoutMs: 60000 },
          )
          if (cloned.exitCode !== 0) {
            return { text: `Could not fetch ${url}: ${firstLine(cloned.stderr) || 'git clone failed'}` }
          }
        } catch (err) {
          return { text: `Could not fetch ${url}: ${err instanceof Error ? err.message : 'git did not run'}` }
        }
      }
    }

    const manifestPath = `${dir}/.claude-plugin/plugin.json`
    const marketPath = `${dir}/.claude-plugin/marketplace.json`
    if ((await $.fs.exists(marketPath)) && !(await $.fs.exists(manifestPath))) {
      let names: string[] = []
      try {
        const market = parseJson(await $.fs.read(marketPath))
        if (isRecord(market) && Array.isArray(market.plugins)) {
          names = market.plugins
            .map(p => (isRecord(p) && typeof p.name === 'string' ? p.name : ''))
            .filter(Boolean)
        }
      } catch {
        // an unreadable marketplace file reads as an empty list
      }
      return {
        text:
          `This is a marketplace with ${names.length} plugin${names.length === 1 ? '' : 's'}: ` +
          `${names.join(', ') || 'none listed'}. Run /preflight on one plugin folder or repo.`,
      }
    }

    let stdout = ''
    let stderr = ''
    try {
      const ran = await $.process.run(['claude', 'plugin', 'validate', '--json', dir], { timeoutMs: 30000 })
      stdout = ran.stdout
      stderr = ran.stderr
    } catch (err) {
      stderr = err instanceof Error ? err.message : 'claude did not run'
    }
    const parsed = parseValidate(stdout)
    if (!parsed) {
      return {
        text:
          `Could not read the report from claude plugin validate for ${dir}: ` +
          `${firstLine(stdout) || firstLine(stderr) || 'it printed nothing'}`,
      }
    }

    let manifest: unknown
    try {
      manifest = parseJson(await $.fs.read(manifestPath))
    } catch {
      manifest = undefined
    }
    let settingsHooks = false
    try {
      const hooksFile = parseJson(await $.fs.read(`${dir}/hooks/hooks.json`))
      settingsHooks = isRecord(hooksFile) && 'hooks' in hooksFile
    } catch {
      // no hooks.json: no settings hooks
    }
    const meta = isRecord(manifest) ? manifest : {}
    const name = typeof meta.name === 'string' && meta.name ? meta.name : baseName(dir)
    const version = typeof meta.version === 'string' && meta.version ? meta.version : 'no version'
    const author = authorOf(meta.author)

    const powers = powersOf(parsed, { settingsHooks, mcpServers: 'mcpServers' in meta })
    const rawLines = rawLinesOf(parsed)
    const all = [parsed.manifest, ...parsed.contents]
    const errorLines = all.flatMap(s => s.errors.map(i => i.message))
    // A report that validate itself marked as failed may be missing hooks or calls: never read it as clean.
    const verdict = parsed.success
      ? verdictOf(powers)
      : `Validation failed (${errorLines.length} error${errorLines.length === 1 ? '' : 's'}): ` +
        `${errorLines[0] ?? 'see the raw lines'}. The powers below may be incomplete.`
    const installCommand =
      source === 'folder'
        ? `claude --plugin-dir ${dir}`
        : `/plugin marketplace add ${arg} then /plugin install ${name}@${name} (edit the marketplace name)`

    await update($, report, () => ({
      dir,
      source,
      url,
      name,
      version,
      author,
      verdict,
      powers,
      rawLines,
      errors: errorLines,
      warnings: all.flatMap(s => s.warnings.map(i => i.message)),
      installCommand,
    }))
    try {
      await $.ui.open({ id: PANE, title: 'Preflight', focus: true, closeOnEscape: true })
    } catch {
      // headless or no surface: the text below is the answer
    }

    const lines = summaryText({ name, version, author }, powers, rawLines, verdict).split('\n')
    if (!parsed.success) lines.splice(1, 0, ...errorLines.map(l => `error: ${l}`))
    return { text: note + lines.join('\n') }
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE) return next(e)

    const { Box, Text, Button } = $.ui.resolve(e)
    const r = await read($, report)
    if (!r) return <Text dimColor>Run /preflight {'<folder | owner/repo | git url>'} first.</Text>

    const cols = Math.max(20, e.props.bodyColumns)
    const color = r.powers.some(p => p.level === 'high')
      ? 'red'
      : r.powers.some(p => p.level === 'medium')
        ? 'yellow'
        : undefined

    const rows = [
      <Text key="name" bold>
        {r.name} {r.version} by {r.author}
      </Text>,
      <Text key="verdict" color={color} dimColor={color === undefined}>
        {r.verdict}
      </Text>,
      <Text key="gap1"> </Text>,
    ]
    r.powers.forEach((p, i) => {
      const glyphColor = p.level === 'high' ? 'red' : p.level === 'medium' ? 'yellow' : undefined
      const room = Math.max(0, cols - p.text.length - 4)
      const cells = [
        <Text
          key="glyph"
          color={glyphColor}
          dimColor={glyphColor === undefined}
          bold={glyphColor !== undefined}
        >
          {glyphOf(p.level)}
        </Text>,
        <Text key="text">{p.text}</Text>,
      ]
      if (room > 12) {
        cells.push(
          <Text key="from" dimColor wrap="truncate">
            {`(from: ${p.from.join(', ')})`}
          </Text>,
        )
      }
      rows.push(
        <Box key={`power-${i}`} flexDirection="row" columnGap={1}>
          {cells}
        </Box>,
      )
    })
    rows.push(<Text key="gap2"> </Text>)
    r.rawLines.forEach((line, i) =>
      rows.push(
        <Text key={`raw-${i}`} dimColor wrap="wrap">
          {line}
        </Text>,
      ),
    )
    r.errors.forEach((line, i) =>
      rows.push(
        <Text key={`err-${i}`} color="red" wrap="wrap">
          {`error: ${line}`}
        </Text>,
      ),
    )
    r.warnings.forEach((line, i) =>
      rows.push(
        <Text key={`warn-${i}`} color="yellow" wrap="wrap">
          {`warning: ${line}`}
        </Text>,
      ),
    )
    rows.push(
      <Box key="buttons" flexDirection="row" columnGap={2} marginTop={1}>
        <Button
          key="copy"
          label="Copy install command"
          hotkey="c"
          onPress={() => {
            void $.ui
              .copy({ text: r.installCommand, surface: e.surface })
              .then(() => $.ui.toast('copied'))
          }}
        />
        <Button key="close" label="Close" hotkey="x" onPress={() => void $.ui.close({ id: PANE })} />
      </Box>,
    )
    rows.push(
      <Text key="footer" dimColor wrap="wrap">
        {FOOTER}
      </Text>,
    )

    return <Box flexDirection="column">{rows}</Box>
  })
}
