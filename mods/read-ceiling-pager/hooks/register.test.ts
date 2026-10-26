import type { On } from 'claude-code'
import { describe, expect, test } from 'claude-code/testing'

import { CHARS_PER_TOKEN, DEFAULT_CAP, HEADROOM, LINE_OVERHEAD, estimateTokens, fit, fitFromError, lineCost, splitLines } from './register'

const SESSION = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const
const FILE = '/work/big.md'

/** A file of `n` lines, each `width` characters wide (plus its newline). */
function fileOf(n: number, width: number): string {
  return Array.from({ length: n }, (_, i) => String(i + 1).padStart(6, '0').padEnd(width, 'x')).join('\n') + '\n'
}

/** The engine's cap error for a window that counted `tokens`. */
function capError(tokens: number, cap = DEFAULT_CAP): string {
  return `File content (${tokens} tokens) exceeds maximum allowed tokens (${cap}). Use offset and limit parameters to read specific portions of the file, or search for specific content instead of reading the whole file.`
}

/**
 * The world beneath the mod: a file system holding one file, and a Read tool that
 * answers with the engine's shape, or with the cap error when `failWith` is set.
 */
function world(
  on: On,
  text: string | null,
  opts: {
    kind?: 'file' | 'dir'
    failWith?: string
    env?: string
    shortenTo?: number
    denyWith?: string
    errorAsText?: boolean
    recordless?: boolean
  } = {},
) {
  const seen: Array<Record<string, unknown>> = []
  const reads = { count: 0 }
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('fs.stat', () => {
    if (text === null) throw new Error('ENOENT')
    return { value: { kind: opts.kind ?? 'file', size: text.length, mtimeMs: 0, isLink: false } }
  })
  on('fs.read', () => {
    reads.count += 1
    if (text === null) throw new Error('ENOENT')
    if (text.length > 4 * 1024 * 1024) throw new Error('over 4 MiB') // as $.fs.read does
    return { value: text }
  })
  on('env.get', () => ({ value: opts.env }))
  on('tool.call', (_$, e) => {
    seen.push(e as unknown as Record<string, unknown>)
    if (opts.denyWith !== undefined) return { deny: opts.denyWith }
    if (opts.failWith !== undefined) {
      // The engine's own errored shape carries the words in `text`, with no result.
      return opts.errorAsText ? { result: undefined, text: opts.failWith, isError: true } : { result: opts.failWith, isError: true }
    }
    const lines = text === null ? [] : splitLines(text)
    const offset = Number((e as { offset?: number }).offset ?? 1)
    const asked = Number((e as { limit?: number }).limit ?? lines.length)
    const limit = Math.min(asked, opts.shortenTo ?? asked) // a hook beneath the mod cut the window
    const page = lines.slice(offset - 1, offset - 1 + limit)
    if (opts.recordless) return { result: page.join('\n') }
    return {
      result: {
        type: 'text',
        file: { filePath: FILE, content: page.join('\n'), numLines: page.length, startLine: offset, totalLines: lines.length },
      },
    }
  })
  return Object.assign(seen, { reads })
}

// 3,000 lines of 120 characters: about 110k tokens as Read returns them, far past the cap.
const BIG = fileOf(3_000, 120)
// The lines of BIG a 25,000-token cap at HEADROOM holds, as the mod computes it.
const FITS = fit(splitLines(BIG), 0, 3_000, Math.floor(DEFAULT_CAP * HEADROOM))

describe('estimate', () => {
  test('counts the line-number prefix and the whole of a long line, as the engine does', () => {
    expect(lineCost('abc')).toBe(3 + LINE_OVERHEAD)
    expect(lineCost('x'.repeat(5_000))).toBe(5_000 + LINE_OVERHEAD)
    expect(estimateTokens(['abcd', 'efgh'])).toBe(Math.ceil((2 * (4 + LINE_OVERHEAD)) / CHARS_PER_TOKEN))
    expect(splitLines('a\nb\n')).toEqual(['a', 'b'])
    expect(splitLines('a\nb')).toEqual(['a', 'b'])
    expect(splitLines('\n')).toEqual([''])
  })

  test('fit returns the longest prefix under the budget, and 0 when the first line is over it', () => {
    const lines = ['a'.repeat(100), 'b'.repeat(100), 'c'.repeat(100)]
    const two = Math.ceil((2 * (100 + LINE_OVERHEAD)) / CHARS_PER_TOKEN)
    expect(fit(lines, 0, 3, two)).toBe(2)
    expect(fit(lines, 1, 3, two)).toBe(2) // from the second line only two remain
    expect(fit(lines, 0, 1, two)).toBe(1) // never more than asked
    expect(fit(['z'.repeat(1_000)], 0, 1, 10)).toBe(0)
  })

  test('reads the retry window read-ceiling-chunk admits out of the engine error', () => {
    // 0.8 x 25,000 x 500 / 26,689 predicts 374; half the failed window, 250, is the hook's limit.
    expect(fitFromError(capError(26_689), 500)).toEqual({ lines: 250, cap: 25_000, tokens: 26_689 })
    // 0.8 x 25,000 x 1,000 / 50,000 is 400, under half the window: the prediction stands.
    expect(fitFromError(capError(50_000), 1_000)).toEqual({ lines: 400, cap: 25_000, tokens: 50_000 })
    // A 5,000-line window: after a refusal the hook admits no more than half the default page.
    expect(fitFromError(capError(26_000), 5_000)).toEqual({ lines: 1_000, cap: 25_000, tokens: 26_000 })
    expect(fitFromError(capError(30_000, 10_000), 1)).toEqual({ lines: 0, cap: 10_000, tokens: 30_000 })
    expect(fitFromError('File does not exist.', 500)).toBeNull()
    expect(fitFromError(capError(26_689), 0)).toBeNull()
    // A long first line beside denser ones: priced past its share, so the advice is that line alone.
    const lopsided = ['word '.repeat(6_000), ...Array.from({ length: 9 }, () => '\u6f22'.repeat(5_000))]
    expect(fitFromError(capError(51_000), 10, lopsided)).toEqual({ lines: 1, cap: 25_000, tokens: 51_000, alone: true })
    // Two lines averaging 22,500 tokens: past 80% of the cap each, so no window, not even that line alone.
    const heavy = ['z'.repeat(30_000), 'z'.repeat(30_000)]
    expect(fitFromError(capError(45_000), 2, heavy)).toEqual({ lines: 0, cap: 25_000, tokens: 45_000, alone: true })
  })

  test('the fixture is big enough to need clamping', () => {
    expect(FITS).toBeGreaterThan(100)
    expect(FITS).toBeLessThan(3_000)
    // 120 + 8 = 128 characters a line; 22,500 tokens x 3.5 = 78,750 characters; 615 whole lines.
    expect(FITS).toBe(615)
  })
})

describe('tool.call', () => {
  test('a window that would exceed the cap is clamped, and the result says where to continue', async ($, on) => {
    const seen = world(on, BIG)
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 1, limit: 2_000 })
    expect(ran.isError).toBeUndefined()
    expect(seen).toHaveLength(1)
    expect(seen[0]?.limit).toBe(FITS)
    expect(seen[0]?.offset).toBe(1)
    const note = ran.context?.at(-1) ?? ''
    expect(note).toContain(`${FILE} has 3000 lines`)
    expect(note).toContain('would exceed the 25000-token Read cap, so this result is lines 1 to 615 (615 of the 2000')
    expect(note).toContain('1385 of them remain: continue with offset 616, limit 615')
  })

  test('the continuation never asks past the window the call asked for', async ($, on) => {
    const seen = world(on, BIG)
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 1_000, limit: 700 })
    expect(seen[0]?.limit).toBe(615) // precondition: clamped
    // lines 1000 to 1614 came back; the 700-line window ends at 1699, so 85 remain
    expect(ran.context?.at(-1)).toContain('(615 of the 700 that window held). 85 of them remain: continue with offset 1615, limit 85.')
  })

  test('the clamp starts where the offset says and never asks past the end of the file', async ($, on) => {
    const seen = world(on, BIG)
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 2_900, limit: 2_000 })
    // 101 lines remain from 2,900: they fit, so nothing to clamp
    expect(seen[0]?.limit).toBe(2_000)
    expect(ran.context).toBeUndefined()

    const far = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 1_000, limit: 2_001 })
    expect(seen[1]?.limit).toBe(FITS)
    expect(far.context?.at(-1)).toContain(`lines 1000 to ${1_000 + FITS - 1}`)
    expect(far.context?.at(-1)).toContain(`${2_001 - FITS} of them remain`)
  })

  test('a window that fits is passed through untouched', async ($, on) => {
    const seen = world(on, BIG)
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 1, limit: 50 })
    expect(seen[0]?.limit).toBe(50)
    expect(ran.context).toBeUndefined()
  })

  test('a small file is passed through without being read by the mod', async ($, on) => {
    const seen = world(on, fileOf(200, 60))
    await $.session.start(SESSION)
    await $.tool.call({ tool: 'Read', file_path: FILE, limit: 5_000 })
    expect(seen[0]?.limit).toBe(5_000)
    expect(seen.reads.count).toBe(0)
  })

  test('a big file is read once per Read that needs the measure', async ($, on) => {
    const seen = world(on, BIG)
    await $.session.start(SESSION)
    await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000 })
    expect(seen.reads.count).toBe(1)
  })

  test('no limit, a PDF page range, a directory and an unreadable path are left to the engine', async ($, on) => {
    const seen = world(on, BIG)
    await $.session.start(SESSION)
    await $.tool.call({ tool: 'Read', file_path: FILE })
    expect(seen[0]?.limit).toBeUndefined()
    await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000, pages: '1-3' })
    expect(seen[1]?.limit).toBe(2_000)
  })

  test('a file past what a mod may read is left to the engine unread', async ($, on) => {
    // $.fs.read rejects past 4 MiB: 36,000 lines of 121 characters is 4,356,000.
    const seen = world(on, fileOf(36_000, 120))
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000 })
    expect(seen[0]?.limit).toBe(2_000)
    expect(seen.reads.count).toBe(0)
    expect(ran.context).toBeUndefined()
  })

  test('a directory is left to the engine', async ($, on) => {
    const seen = world(on, BIG, { kind: 'dir' })
    await $.session.start(SESSION)
    await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000 })
    expect(seen[0]?.limit).toBe(2_000)
  })

  test('a path the mod cannot stat is left to the engine', async ($, on) => {
    const seen = world(on, null)
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000 })
    expect(seen[0]?.limit).toBe(2_000)
    expect(ran.context).toBeUndefined()
  })

  test('a clamped Read the engine still refuses gets the window its own numbers say fits', async ($, on) => {
    const seen = world(on, BIG, { failWith: capError(27_000) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 1, limit: 2_000 })
    expect(ran.isError).toBe(true)
    expect(seen[0]?.limit).toBe(FITS)
    const note = ran.context?.at(-1) ?? ''
    expect(note).toContain(`${FITS} lines from line 1 came to 27000 tokens`)
    expect(note).toContain('already clamped from 2000 by read-ceiling-pager')
    // 0.8 x 25,000 x 615 / 27,000 predicts 455; half the 615 that failed is 307.
    expect(note).toContain('retry with offset 1, limit 307, then continue from offset 308')
  })

  test('an untouched Read the engine refuses gets the same help', async ($, on) => {
    world(on, BIG, { failWith: capError(26_689) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 1, limit: 50 })
    expect(ran.isError).toBe(true)
    expect(ran.context?.at(-1)).toContain(`50 lines from line 1 came to 26689 tokens`)
    // 0.8 x 25,000 x 50 / 26,689 predicts 37; half of 50 is 25.
    expect(ran.context?.at(-1)).toContain('retry with offset 1, limit 25, then continue from offset 26')
    expect(ran.context?.at(-1)).not.toContain('already clamped')
  })

  test('a refused Read the mod passed unread is measured by the lines the file really has', async ($, on) => {
    // 60 lines of 1,000 characters pass the size check unread; dense text can still count past the cap.
    const seen = world(on, fileOf(60, 1_000), { failWith: capError(30_000) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000 })
    expect(seen[0]?.limit).toBe(2_000) // precondition: the call went through untouched
    const note = ran.context?.at(-1) ?? ''
    expect(note).toContain('60 lines from line 1 came to 30000 tokens')
    // 0.8 x 25,000 x 60 / 30,000 predicts 40; half of 60 is 30.
    expect(note).toContain('retry with offset 1, limit 30, then continue from offset 31')
    expect(seen.reads.count).toBe(1) // read once, after the refusal

    const tail = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 41, limit: 2_000 })
    expect(tail.context?.at(-1)).toContain('20 lines from line 41 came to 30000 tokens')
  })

  test('a single line past the cap is left alone and the error points at Grep', async ($, on) => {
    // The live probe's numbers: one 450,000-character line came to 300,008 tokens at limit 1.
    const seen = world(on, 'x'.repeat(450_000) + '\n', { failWith: capError(300_008) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 1 })
    expect(seen[0]?.limit).toBe(1) // precondition: nothing to clamp to
    expect(ran.isError).toBe(true)
    expect(ran.context?.at(-1)).toContain('no window of whole lines fits')
    expect(ran.context?.at(-1)).toContain('Grep')
  })

  test('a refused window whose long first line outweighs its share is retried at that line alone', async ($, on) => {
    // Prose then dense CJK: about 6,000 + 45,000 tokens. At the window's average density line 1 looks over
    // the cap, yet on its own it is about 6,000 tokens, so the note must not rule it out.
    const lines = ['word '.repeat(6_000), ...Array.from({ length: 9 }, () => '\u6f22'.repeat(5_000))]
    const seen = world(on, lines.join('\n') + '\n', { failWith: capError(51_000) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 10 })
    expect(seen[0]?.limit).toBe(10) // precondition: the estimate passed it untouched
    const note = ran.context?.at(-1) ?? ''
    expect(note).toContain('10 lines from line 1 came to 51000 tokens')
    expect(note).toContain('retry with offset 1, limit 1, then continue from offset 2')
    expect(note).not.toContain('Grep')
  })

  test('a refused window whose lines average past the headroom gets Grep, not a retry window', async ($, on) => {
    const seen = world(on, 'z'.repeat(30_000) + '\n' + 'z'.repeat(30_000) + '\n', { failWith: capError(45_000) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2 })
    expect(seen[0]?.limit).toBe(2) // precondition: the estimate passed it untouched
    const note = ran.context?.at(-1) ?? ''
    // read-ceiling-chunk.js admits floor(0.8 x 25,000 x 2 / 45,000) = 0 lines after this, so no Read is advised.
    expect(note).toContain('about 22500 tokens a line on average, more than 80% of the cap')
    expect(note).toContain('Grep')
    expect(note).not.toContain('retry with')
    expect(note).not.toContain('no window of whole lines fits')
  })

  test('a refused window with a far longer line inside is advised up to that line', async ($, on) => {
    // Dense text: the 60,000-character line passes the estimate, then is priced at its share of the engine's count.
    const lines = ['a', 'b', '\u6f22'.repeat(60_000), ...Array.from({ length: 97 }, () => 'c')]
    const seen = world(on, lines.join('\n') + '\n', { failWith: capError(70_000) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 100 })
    expect(seen[0]?.limit).toBe(100) // precondition: untouched
    // Proportion alone gives 0.8 x 25,000 x 100 / 70,000 = 28 lines, which would hold line 3 again.
    expect(ran.context?.at(-1)).toContain('retry with offset 1, limit 2, then continue from offset 3')
  })

  test('a refused PDF page range gets no offset and limit advice', async ($, on) => {
    const seen = world(on, BIG, { failWith: capError(30_000) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000, pages: '1-3' })
    expect(seen[0]?.pages).toBe('1-3') // precondition: passed untouched
    expect(ran.isError).toBe(true)
    expect(ran.context).toBeUndefined()
  })

  test('another error is passed through without comment', async ($, on) => {
    world(on, BIG, { failWith: 'File does not exist.' })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000 })
    expect(ran.isError).toBe(true)
    expect(ran.context).toBeUndefined()
  })

  test('the env override raises the cap', async ($, on) => {
    const seen = world(on, BIG, { env: '1000000' })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000 })
    expect(seen[0]?.limit).toBe(2_000) // a million-token cap holds the whole window
    expect(ran.context).toBeUndefined()
  })

  test('a window shortened beneath the mod is described by the lines the engine returned', async ($, on) => {
    // read-ceiling-chunk.js runs an oversize call it has denied three times at its own, smaller window.
    const seen = world(on, BIG, { shortenTo: 100 })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 1, limit: 2_000 })
    expect(seen[0]?.limit).toBe(FITS) // precondition: the mod clamped, and the world beneath cut further
    const note = ran.context?.at(-1) ?? ''
    expect(note).toContain('was shortened before it ran, so this result is lines 1 to 100 (100 of the 2000')
    expect(note).toContain('1900 of them remain: continue with offset 101, limit 100')
    expect(note).not.toContain(`to ${FITS}`)
  })

  test('a window that fits and comes back short still says where to continue', async ($, on) => {
    const seen = world(on, BIG, { shortenTo: 20 })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 11, limit: 50 })
    expect(seen[0]?.limit).toBe(50) // precondition: the mod passed the call untouched
    const note = ran.context?.at(-1) ?? ''
    expect(note).toContain('this result is lines 11 to 30 (20 of the 50')
    expect(note).toContain('30 of them remain: continue with offset 31, limit 20')
  })

  test('a Read with no limit is left to the engine even when its result is short', async ($, on) => {
    world(on, BIG, { shortenTo: 100 })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE })
    expect(ran.context).toBeUndefined()
  })

  test('a long line counts whole, so a window holding one is clamped before it', async ($, on) => {
    const seen = world(on, 'short first line\n' + 'y'.repeat(200_000) + '\nshort third line\n')
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 3 })
    expect(seen[0]?.limit).toBe(1)
    expect(ran.context?.at(-1)).toContain('this result is lines 1 to 1 (1 of the 3 that window held)')
  })

  test('an offset past the end is left to the engine', async ($, on) => {
    const seen = world(on, BIG)
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 3_500, limit: 2_000 })
    expect(seen[0]?.limit).toBe(2_000)
    expect(ran.context).toBeUndefined()
  })

  test('a deny from a hook beneath passes through untouched', async ($, on) => {
    world(on, BIG, { denyWith: 'Read stopped before running.' })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000 })
    expect(ran.deny).toBe('Read stopped before running.')
    expect(ran.context).toBeUndefined()
  })

  test('a result with no lines gets no note', async ($, on) => {
    const seen = world(on, BIG, { shortenTo: 0 })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, limit: 50 })
    expect(seen[0]?.limit).toBe(50) // precondition: untouched, and nothing came back
    expect(ran.context).toBeUndefined()
  })

  test('a clamped Read whose result carries no line record still says where to continue', async ($, on) => {
    const seen = world(on, BIG, { recordless: true })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 1, limit: 2_000 })
    expect(seen[0]?.limit).toBe(615) // precondition: clamped
    expect(ran.context?.at(-1)).toContain('this result is lines 1 to 615 (615 of the 2000 that window held)')
  })

  test("the engine's errored shape, words in text and no result, gets the same help", async ($, on) => {
    world(on, BIG, { failWith: capError(26_689), errorAsText: true })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'Read', file_path: FILE, offset: 1, limit: 50 })
    expect(ran.isError).toBe(true)
    expect(ran.context?.at(-1)).toContain('retry with offset 1, limit 25, then continue from offset 26')
  })

  test('an env override that is not a positive number leaves the default cap', async ($, on) => {
    const seen = world(on, BIG, { env: 'lots' })
    await $.session.start(SESSION)
    await $.tool.call({ tool: 'Read', file_path: FILE, limit: 2_000 })
    expect(seen[0]?.limit).toBe(FITS)
  })

  test('other tools are not touched', async ($, on) => {
    const seen = world(on, BIG)
    await $.session.start(SESSION)
    await $.tool.call({ tool: 'Bash', command: 'ls' })
    expect(seen).toHaveLength(1)
    expect(seen[0]?.command).toBe('ls')
  })
})
