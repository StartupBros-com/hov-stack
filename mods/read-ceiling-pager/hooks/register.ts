import type { EngineInterface, Register } from 'claude-code'

/**
 * read-ceiling-pager: a Read window that would exceed the token cap is clamped
 * to the lines that fit, and the result says where to continue.
 *
 * Claude Code refuses a Read whose content counts past its cap (25,000 tokens
 * unless CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS says otherwise) with an error
 * that tells the model to use offset and limit. A whole-file Read is already
 * paginated by the engine; an explicit window that is too big is not, and the
 * failures measured in this harness were all explicit windows (the guard hook
 * read-ceiling-chunk.js carries the survey). Each one costs a round: the call,
 * the error, a smaller retry.
 *
 * Before such a Read runs, this mod reads the file itself, estimates the
 * requested window's tokens (characters plus the line-number prefix the Read
 * tool adds, a long line counted whole as the engine counts it), and when the
 * estimate is over the cap rewrites `limit` to the largest prefix of the window
 * that fits. The result the model gets is the engine's own numbered lines for
 * that prefix, plus one context line naming the lines returned, the lines left,
 * and the offset and limit that continue. That line is built from the engine's
 * record of the lines it returned, so it stays right when a hook beneath this
 * one shortens the window further, and an explicit window that comes back short
 * for any other reason gets the same line. A window that fits, a Read with no
 * limit, a PDF page range, a file the mod cannot stat or read, and a file too
 * large to scan are passed through untouched.
 *
 * The engine counts tokens exactly where this mod estimates, so a clamped Read
 * can still be refused. Then, and when an untouched Read is refused, the mod
 * reads the engine's own numbers out of the error (tokens counted, cap) and
 * adds a window to retry with: the one the harness's read-ceiling-chunk.js
 * hook admits after a first refusal of the file, so following it is not denied
 * then. After more refusals of the same file that hook's window can be smaller;
 * it denies once and names it. The count is also spread over the window's
 * characters, so the advice stops before a line far longer than the rest. When
 * the first line alone outweighs its share, the advice is that line alone:
 * density varies from line to line, so only the engine refusing a one-line
 * window shows a line is over the cap.
 */

/** Claude Code's default Read cap, in tokens. */
export const DEFAULT_CAP = 25_000
/** Characters per token the estimate assumes: conservative for typical code and prose; dense text (minified JSON, CJK) can run below it, and the refusal path covers that. */
export const CHARS_PER_TOKEN = 3.5
/** The estimate aims this far under the cap; the engine's count is exact and this is not. */
export const HEADROOM = 0.9
/** Characters the Read tool adds per line for its line-number prefix. */
export const LINE_OVERHEAD = 8
/** read-ceiling-chunk.js aims a retry at this fraction of the cap (its FIT_HEADROOM); advice above its window is denied there. */
export const RETRY_HEADROOM = 0.8
/** $.fs.read rejects a file over 4 MiB, so files past this are left to the engine. */
export const MAX_FILE_BYTES = 4 * 1024 * 1024
/** The Read tool's own page when no limit is given. */
export const DEFAULT_PAGE = 2_000

const CEILING = /\((\d+) tokens\) exceeds maximum allowed tokens \((\d+)\)/

/**
 * What one line costs in characters once Read has numbered it. The engine counts
 * a long line whole: one 450,000-character line came to 300,008 tokens at
 * limit 1 (probed 2026-10-04).
 */
export function lineCost(line: string): number {
  return line.length + LINE_OVERHEAD
}

/** The estimated tokens of these lines as Read would return them. */
export function estimateTokens(lines: readonly string[]): number {
  let chars = 0
  for (const line of lines) chars += lineCost(line)
  return Math.ceil(chars / CHARS_PER_TOKEN)
}

/**
 * The file's lines as read-ceiling-chunk.js counts them: a trailing newline ends
 * the last line. The Read tool also numbers the empty line after it, which costs
 * only its prefix; the retry advice has to agree with that hook's count.
 */
export function splitLines(text: string): string[] {
  const lines = text.split('\n')
  if (lines.length > 1 && text.endsWith('\n')) lines.pop()
  return lines
}

/**
 * How many lines from index `start` fit under `budget` tokens, at most `want`.
 * 0 when the first line alone does not fit.
 */
export function fit(lines: readonly string[], start: number, want: number, budget: number): number {
  return fitChars(lines, start, want, budget * CHARS_PER_TOKEN)
}

/** How many lines from index `start` fit in `limitChars` characters as Read returns them, at most `want`. */
function fitChars(lines: readonly string[], start: number, want: number, limitChars: number): number {
  let chars = 0
  let n = 0
  while (n < want && start + n < lines.length) {
    const cost = lineCost(lines[start + n] ?? '')
    if (chars + cost > limitChars) break
    chars += cost
    n += 1
  }
  return n
}

/**
 * From the engine's own cap error for a window of `windowLines` lines: the window
 * to retry with, and the cap and count it named. null when the text is not that
 * error. The window is the one read-ceiling-chunk.js admits after one refusal
 * (its rungFor with one failure on record): the error's own prediction at
 * RETRY_HEADROOM, and no more than half the window that failed or half the
 * default page. After more refusals of the same file that hook's window can be
 * smaller still; it then denies once and names it.
 *
 * Given the window's own lines, the count is also spread over their characters:
 * a line far longer than the rest is priced at its share, so the advice stops
 * before it. When the first line alone outweighs its share, `alone` is set and
 * the window is that one line (none when the window above admits none): the
 * error counts the whole window, and a low-density first line beside denser
 * ones can still fit by itself.
 */
export function fitFromError(
  text: string,
  windowLines: number,
  window?: readonly string[],
): { lines: number; cap: number; tokens: number; alone?: true } | null {
  const m = CEILING.exec(text)
  if (!m) return null
  const tokens = Number(m[1])
  const cap = Number(m[2])
  if (!(tokens > 0) || !(cap > 0) || !(windowLines > 0)) return null
  const predicted = Math.floor((RETRY_HEADROOM * cap * windowLines) / tokens)
  const lines = Math.min(predicted, Math.floor(windowLines / 2), Math.floor(DEFAULT_PAGE / 2))
  if (window === undefined || window.length === 0) return { lines, cap, tokens }
  let chars = 0
  for (const line of window) chars += lineCost(line)
  const priced = fitChars(window, 0, window.length, (RETRY_HEADROOM * cap * chars) / tokens)
  if (priced > 0) return { lines: Math.min(lines, priced), cap, tokens }
  return { lines: Math.min(lines, 1), cap, tokens, alone: true }
}

function positiveInt(value: unknown): number | null {
  const n = Number(value)
  return Number.isInteger(n) && n > 0 ? n : null
}

/** The cap the engine enforces: its env override when set and positive, else the default. */
async function capOf($: EngineInterface): Promise<number> {
  try {
    const raw = await $.env.get('CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS')
    const n = Number(raw)
    return raw !== undefined && Number.isFinite(n) && n > 0 ? Math.floor(n) : DEFAULT_CAP
  } catch {
    return DEFAULT_CAP
  }
}

/** What this mod decided for one Read: the window the engine will see, and the clamp if any. */
export type Plan = {
  /** The lines the engine reads if the call runs as asked (for reading its error later). */
  window: number
  /** The limit to rewrite to; absent when the call passes through untouched. */
  clamp?: number
  offset: number
  limit: number
  /** The call named its own limit and no PDF pages: a result shorter than that window gets a note. */
  explicit: boolean
  /** A PDF page range: offset and limit do not apply to it. */
  paged: boolean
  /** The file's lines, when the mod read them before the call. */
  lines?: readonly string[]
  total: number
  cap: number
  file: string
}

async function planFor(
  $: EngineInterface,
  call: { file_path: string; offset?: number; limit?: number; pages?: string },
): Promise<Plan> {
  const file = call.file_path
  const limit = positiveInt(call.limit)
  const offset = positiveInt(call.offset) ?? 1
  const paged = call.pages !== undefined
  const explicit = limit !== null && !paged
  const pass: Plan = {
    window: limit ?? DEFAULT_PAGE,
    offset,
    limit: limit ?? DEFAULT_PAGE,
    explicit,
    paged,
    total: 0,
    cap: DEFAULT_CAP,
    file,
  }
  // No limit: the engine paginates a whole-file read itself. A page range is a PDF.
  if (limit === null || !explicit) return pass

  let size: number
  try {
    const st = await $.fs.stat(file)
    if (st.kind !== 'file' || st.size > MAX_FILE_BYTES) return pass
    size = st.size
  } catch {
    return pass
  }
  const cap = await capOf($)
  pass.cap = cap
  const budget = Math.floor(cap * HEADROOM)
  // The whole file plus every line's prefix fits: nothing to clamp, no need to read it.
  if (size + limit * LINE_OVERHEAD <= budget * CHARS_PER_TOKEN) return pass

  let text: string
  try {
    text = await $.fs.read(file)
  } catch {
    return pass
  }
  const lines = splitLines(text)
  const start = offset - 1
  pass.lines = lines
  pass.total = lines.length
  if (start >= lines.length) return pass // past the last line: nothing to clamp
  const want = Math.min(limit, lines.length - start)
  pass.window = want
  if (estimateTokens(lines.slice(start, start + want)) <= budget) return pass
  const n = fit(lines, start, want, budget)
  if (n === 0 || n >= want) return pass // one line alone is over the cap, or the estimate disagrees with itself
  return { ...pass, clamp: n }
}

/**
 * The lines the engine read for a refused call. A plan that read the file has
 * them; one that passed early (a file small enough to skip, no limit, a failed
 * stat) knows only what was asked, which can be far more than the file holds, so
 * the file is read now, after the refusal. null when it cannot be read.
 */
async function windowRead($: EngineInterface, plan: Plan): Promise<readonly string[] | null> {
  let lines = plan.lines
  if (lines === undefined) {
    try {
      const st = await $.fs.stat(plan.file)
      if (st.kind !== 'file' || st.size > MAX_FILE_BYTES) return null
      lines = splitLines(await $.fs.read(plan.file))
    } catch {
      return null
    }
  }
  const start = plan.offset - 1
  return lines.slice(start, start + (plan.clamp ?? plan.limit))
}

/** The lines a Read returned, from the engine's own record; null when the result is not a text record. */
export function returnedOf(result: unknown): { start: number; count: number; total: number } | null {
  if (typeof result !== 'object' || result === null) return null
  const r = result as { type?: unknown; file?: { startLine?: unknown; numLines?: unknown; totalLines?: unknown } | null }
  if (r.type !== 'text' || typeof r.file !== 'object' || r.file === null) return null
  const { startLine, numLines, totalLines } = r.file
  const whole = (n: unknown): n is number => typeof n === 'number' && Number.isInteger(n) && n >= 0
  return whole(startLine) && whole(numLines) && whole(totalLines) ? { start: startLine, count: numLines, total: totalLines } : null
}

function withContext<R extends { context?: readonly string[] }>(ran: R, line: string): R {
  return { ...ran, context: [...(ran.context ?? []), line] }
}

/** The words the model reads for a failed call: core's `text`, else a string result. */
export function failureTextOf(ran: { text?: string; result?: unknown }): string {
  if (typeof ran.text === 'string') return ran.text
  return typeof ran.result === 'string' ? ran.result : ''
}

export const register: Register = on => {
  on('tool.call', { tool: 'Read' }, async ($, e, next) => {
    const plan = await planFor($, e)
    const ran = await next(plan.clamp === undefined ? e : { ...e, limit: plan.clamp })
    if (ran.deny !== undefined) return ran

    if (ran.isError !== true) {
      if (!plan.explicit) return ran
      // The engine's record says which lines came back, whoever shortened the window: this
      // mod's clamp, or a hook beneath it (read-ceiling-chunk.js rewrites an ignored oversize call).
      // Without that record, the mod's own clamp is the best account of what ran.
      const got =
        returnedOf(ran.result) ?? (plan.clamp === undefined ? null : { start: plan.offset, count: plan.clamp, total: plan.total })
      if (got === null || got.count === 0) return ran
      const end = Math.min(plan.offset + plan.limit - 1, got.total)
      const last = got.start + got.count - 1
      if (last >= end) return ran
      const left = end - last
      const why = got.count === plan.clamp ? `would exceed the ${plan.cap}-token Read cap` : 'was shortened before it ran'
      return withContext(
        ran,
        `read-ceiling-pager: ${plan.file} has ${got.total} lines. The ${plan.limit}-line window from line ${plan.offset} ` +
          `${why}, so this result is lines ${got.start} to ${last} ` +
          `(${got.count} of the ${end - plan.offset + 1} that window held). ${left} of them remain: continue with ` +
          `offset ${last + 1}, limit ${Math.min(got.count, left)}.`,
      )
    }

    // The engine refused the window anyway: its error names the exact count, so say what fits.
    // Offset and limit do not apply to a PDF page range.
    if (plan.paged) return ran
    const text = failureTextOf(ran)
    if (!CEILING.test(text)) return ran
    const read = await windowRead($, plan)
    const ranLines = read === null ? (plan.clamp ?? plan.window) : read.length
    const found = fitFromError(text, ranLines, read ?? undefined)
    if (!found) return ran
    const clamped = plan.clamp === undefined ? '' : ` (already clamped from ${plan.limit} by read-ceiling-pager)`
    const counted =
      `read-ceiling-pager: ${ranLines} line${ranLines === 1 ? '' : 's'} from line ${plan.offset} came to ${found.tokens} tokens ` +
      `against a ${found.cap}-token cap${clamped}`
    if (found.lines <= 0 && ranLines > 1) {
      // Only an average: a single line here may still fit, but no retry window keeps the headroom.
      return withContext(
        ran,
        `${counted}: about ${Math.ceil(found.tokens / ranLines)} tokens a line on average, more than ` +
          `${Math.round(RETRY_HEADROOM * 100)}% of the cap, so the count leaves no retry window with room to spare. ` +
          `Search the file with Grep, or extract a byte range with a Bash command, instead of another Read.`,
      )
    }
    if (found.lines <= 0) {
      return withContext(
        ran,
        `${counted}; no window of whole lines fits here. Search the file with Grep, or extract a byte range with a Bash ` +
          `command, instead of another Read.`,
      )
    }
    if (found.alone) {
      return withContext(
        ran,
        `${counted}. At that window's average density line ${plan.offset} alone would pass ` +
          `${Math.round(RETRY_HEADROOM * 100)}% of the cap, but density varies from line to line, so try it alone: ` +
          `retry with offset ${plan.offset}, limit 1, then continue from offset ${plan.offset + 1}.`,
      )
    }
    return withContext(
      ran,
      `${counted}. A window of ${found.lines} line${found.lines === 1 ? '' : 's'} fits with room to spare: ` +
        `retry with offset ${plan.offset}, limit ${found.lines}, then continue from offset ${plan.offset + found.lines}.`,
    )
  })
}
