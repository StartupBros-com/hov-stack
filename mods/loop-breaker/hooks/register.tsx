import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

/**
 * loop-breaker: the same tool call failing again and again is a loop.
 *
 * Every tool call is keyed by its agent, its tool and its normalised
 * arguments. A call that errors or is refused counts one failure for that
 * key; a success clears it. At `threshold - 1` failures the result carries a
 * hint Claude reads. At `threshold` failures the next identical attempt is
 * refused before it runs, with a reason Claude can act on. The band above
 * the prompt shows how bad it is and offers Stop and rethink.
 */

const worst = atom({ plugin: 'loop-breaker', key: 'worst' } as const, 0)
const lastTool = atom(
  { plugin: 'loop-breaker', key: 'lastTool' } as const,
  null as string | null,
)

const MAX_KEY = 8_000
const MAX_KEYS = 500
const DEFAULT_THRESHOLD = 3

/** JSON with sorted keys and trimmed strings, so whitespace is not "different arguments". */
export function stable(value: unknown): string {
  if (typeof value === 'string') return JSON.stringify(value.trim())
  if (value === null || typeof value !== 'object') return String(JSON.stringify(value))
  if (Array.isArray(value)) return '[' + value.map(stable).join(',') + ']'
  const record = value as Record<string, unknown>
  return (
    '{' +
    Object.keys(record)
      .sort()
      .map(key => JSON.stringify(key) + ':' + stable(record[key]))
      .join(',') +
    '}'
  )
}

/** FNV-1a over the whole string, as two 32-bit lanes, so a long call never collides by truncation. */
export function fnv1a(text: string): string {
  let a = 0x811c9dc5
  let b = 0x01000193
  for (let i = 0; i < text.length; i += 1) {
    const c = text.charCodeAt(i)
    a = Math.imul(a ^ c, 0x01000193) >>> 0
    b = Math.imul(b ^ c, 0x811c9dc5) >>> 0
  }
  return a.toString(16).padStart(8, '0') + b.toString(16).padStart(8, '0')
}

/** The identity of a call: who made it, which tool, which arguments (hashed in full). */
export function keyOf(e: {
  tool: string
  tool_use_id?: string
  agentId?: string
  [k: string]: unknown
}): string {
  const { tool, tool_use_id: _id, agentId, ...args } = e
  const canonical = stable(args)
  const body = canonical.length <= MAX_KEY ? canonical : `${canonical.length}:${fnv1a(canonical)}`
  return `${agentId ?? 'main'}\u0000${tool}\u0000${body}`
}

function thresholdOf(value: unknown): number {
  const n = Math.floor(Number(value))
  return Number.isFinite(n) && n >= 2 && n <= 20 ? n : DEFAULT_THRESHOLD
}

function allowOf(value: unknown): Set<string> {
  const list = Array.isArray(value) ? value : String(value ?? '').split(',')
  return new Set(list.map(s => String(s).trim()).filter(Boolean))
}

/**
 * Failures that mean "try again later", not "this approach is wrong": an
 * admission guard deferring a heavy job, a rate limit, a dropped connection.
 * Retrying those identically is the right move, so they never count.
 */
export const DEFAULT_RETRY_LATER =
  'deferred|try again later|retry after|rate limit|too many requests|\\b429\\b|\\b503\\b|ECONNRESET|ETIMEDOUT|EAGAIN|temporarily unavailable|already running'

/** Only the head of a failure is read for retry-later words: a guard or a server says so up front. */
export const RETRY_LATER_HEAD = 400

function retryLaterOf(value: unknown): RegExp | null {
  const source = typeof value === 'string' ? value.trim() : ''
  if (source === '') return null
  try {
    return new RegExp(source, 'i')
  } catch {
    return new RegExp(DEFAULT_RETRY_LATER, 'i')
  }
}

/** The words the model reads for a failed call, whatever shape the result took. */
function failureTextOf(ran: { deny?: string; text?: string; result?: unknown }): string {
  if (ran.deny !== undefined) return ran.deny
  if (typeof ran.text === 'string') return ran.text
  if (typeof ran.result === 'string') return ran.result
  try {
    return JSON.stringify(ran.result) ?? ''
  } catch {
    return ''
  }
}

export const register: Register = (on, options) => {
  const threshold = thresholdOf(options.threshold)
  const allow = allowOf(options.allow)
  const retryLater = retryLaterOf(options.retryLater ?? DEFAULT_RETRY_LATER)

  /** Failures per call key, this turn. Module-level: a reload starts clean, which is fine. */
  const fails = new Map<string, number>()
  let turnId: string | null = null

  on('turn.start', async ($, e, next) => {
    turnId = e.turnId
    fails.clear()
    await update($, worst, () => 0)
    await update($, lastTool, () => null)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (!e.agentId) turnId = null
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    if (allow.has(e.tool)) return next(e)

    const key = keyOf(e as Parameters<typeof keyOf>[0])
    const seen = fails.get(key) ?? 0

    if (seen >= threshold) {
      await update($, worst, w => Math.max(w, threshold + 1))
      await update($, lastTool, () => e.tool)
      $.ui.toast(`loop broken: ${e.tool} failed ${seen}x with identical arguments`)
      return {
        deny:
          `loop-breaker refused this ${e.tool} call: it has failed ${seen} times in a row ` +
          `with identical arguments. Do not retry it unchanged. State what you tried and what ` +
          `the error said, then take a different approach: different arguments, a different ` +
          `tool, or ask the user.`,
      }
    }

    const ran = await next(e)
    const failed = ran.deny !== undefined || ran.isError === true

    if (!failed) {
      fails.delete(key)
      return ran
    }

    // "Try again later" is not a loop: leave the count where it is.
    if (retryLater && retryLater.test(failureTextOf(ran).slice(0, RETRY_LATER_HEAD))) return ran

    const count = seen + 1
    if (fails.size >= MAX_KEYS && !fails.has(key)) {
      const oldest = fails.keys().next().value
      if (oldest !== undefined) fails.delete(oldest)
    }
    fails.set(key, count)
    await update($, worst, w => Math.max(w, count))

    if (count === threshold - 1 && ran.deny === undefined) {
      return {
        ...ran,
        context: [
          ...(ran.context ?? []),
          `loop-breaker: this exact ${e.tool} call has now failed ${count} times with identical ` +
            `arguments. Do not retry it unchanged. Read the error and change the arguments or ` +
            `the approach. The next identical attempt after ${threshold} failures will be refused.`,
        ],
      }
    }

    return ran
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    const level = await read($, worst)

    if (e.props.hasSurvey || level < threshold - 1) return below

    const { Box, Text, Button } = $.ui.resolve(e)
    const tool = await read($, lastTool)

    const face =
      level > threshold
        ? { glyph: '(>_<)', color: 'red', text: `loop broken: ${tool ?? 'a tool'} refused after ${threshold} identical failures` }
        : level === threshold
          ? { glyph: '(O_O)', color: 'red', text: `${level} identical failures in a row; the next identical try is refused` }
          : { glyph: '(o_o)', color: 'yellow', text: `${level} identical failures in a row` }

    const stop = async () => {
      const id = turnId
      await update($, worst, () => 0)
      if (id) {
        try {
          await $.turn.abort({ turnId: id })
        } catch {
          // the turn had already ended; nothing to stop
        }
      }
      try {
        await $.prompt.submit({
          text:
            'Stop. The same call kept failing. In two or three sentences: what did you try, ' +
            'what did the error say, and what different approach will you take? Then proceed ' +
            'with that approach.',
        })
      } catch {
        // nothing to submit into (a headless run); the abort alone was the point
      }
    }

    const buttons = []
    if (e.props.isWorking && turnId) {
      buttons.push(
        <Button key="stop" label="Stop and rethink" hotkey="r" onPress={() => void stop()} />,
      )
    }
    buttons.push(
      <Button
        key="dismiss"
        label="Dismiss"
        hotkey="d"
        plain
        onPress={() => void update($, worst, () => 0)}
      />,
    )

    const rows = [
      <Box key="face" flexDirection="row" columnGap={2}>
        <Text key="glyph" color={face.color} bold>
          {face.glyph}
        </Text>
        <Text key="text" dimColor>
          {face.text}
        </Text>
        {buttons}
      </Box>,
    ]
    if (below) rows.push(below)

    return <Box flexDirection="column">{rows}</Box>
  })
}
