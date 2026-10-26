import type { On } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import { keyOf, stable } from './register'

const SESSION = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const
const CALL = { tool: 'Bash', command: 'make test' } as const

const BAND = {
  plugin: 'loop-breaker',
  surface: 'terminal',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: true,
    maxRows: 10,
    bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
  viewport: { columns: 120, rows: 40 },
} as const

/** Beneath the mod nothing draws in the band: an empty Box, as the engine's own band is empty. */
function emptyBand(on: On) {
  on('ui.render', ($, e) => {
    const { Box } = $.ui.resolve(e)
    return Box({ children: [] })
  })
}

/** The world beneath: every tool call errors. */
function failingWorld(on: On) {
  mock.clock(on)
  emptyBand(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: 'boom', isError: true }))
}

describe('register', () => {
  test('stable keys ignore key order and whitespace', async () => {
    expect(stable({ b: 1, a: ' x ' })).toBe(stable({ a: 'x', b: 1 }))
    expect(keyOf({ tool: 'Bash', command: 'ls' })).toBe(keyOf({ tool: 'Bash', command: 'ls ', tool_use_id: 'u1' }))
    expect(keyOf({ tool: 'Bash', command: 'ls' })).not.toBe(keyOf({ tool: 'Bash', command: 'ls -la' }))
    expect(keyOf({ tool: 'Bash', command: 'ls' })).not.toBe(keyOf({ tool: 'Bash', command: 'ls', agentId: 'a1' }))
  })

  test('two long calls that differ only at the end are different calls', async ($, on) => {
    failingWorld(on)
    await $.session.start(SESSION)
    const prefix = 'x'.repeat(9_000)
    const a = { tool: 'Write', file_path: 'big.txt', content: `${prefix}A` } as const
    const b = { tool: 'Write', file_path: 'big.txt', content: `${prefix}B` } as const
    expect(keyOf(a)).not.toBe(keyOf(b))
    for (let i = 0; i < 3; i += 1) await $.tool.call(a)
    expect((await $.tool.call(b)).deny).toBeUndefined()
    expect((await $.tool.call(a)).deny).toContain('loop-breaker')
  })

  test('the same failing call is hinted, then refused after the threshold', async ($, on) => {
    failingWorld(on)
    await $.session.start(SESSION)

    const first = await $.tool.call(CALL)
    expect(first.isError).toBe(true)
    expect(first.context).toBeUndefined()

    const second = await $.tool.call(CALL)
    expect(second.isError).toBe(true)
    expect(second.context?.[0]).toContain('failed 2 times')

    const third = await $.tool.call(CALL)
    expect(third.isError).toBe(true)
    expect(third.deny).toBeUndefined()

    const fourth = await $.tool.call(CALL)
    expect(fourth.deny).toContain('loop-breaker refused this Bash call')
    expect(fourth.deny).toContain('failed 3 times')
  })

  test('different arguments and different agents are counted apart', async ($, on) => {
    failingWorld(on)
    await $.session.start(SESSION)

    for (let i = 0; i < 3; i += 1) await $.tool.call(CALL)
    const other = await $.tool.call({ tool: 'Bash', command: 'make lint' })
    expect(other.deny).toBeUndefined()
    // A subagent's call carries agentId; the engine sets it, so the test spells it past the type.
    const sub = await $.tool.call({ ...CALL, agentId: 'agent-1' } as typeof CALL)
    expect(sub.deny).toBeUndefined()
    const same = await $.tool.call(CALL)
    expect(same.deny).toContain('loop-breaker')
  })

  test('a success clears the count', async ($, on) => {
    mock.clock(on)
    let calls = 0
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('tool.call', () => {
      calls += 1
      return calls === 3 ? { result: 'ok' } : { result: 'boom', isError: true }
    })
    await $.session.start(SESSION)

    await $.tool.call(CALL)
    await $.tool.call(CALL)
    const ok = await $.tool.call(CALL)
    expect(ok.isError).toBeUndefined()
    const again = await $.tool.call(CALL)
    expect(again.deny).toBeUndefined()
    expect(again.isError).toBe(true)
  })

  test('a refused call counts as a failure too', async ($, on) => {
    mock.clock(on)
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('tool.call', () => ({ deny: 'not here' }))
    await $.session.start(SESSION)

    for (let i = 0; i < 3; i += 1) {
      const r = await $.tool.call(CALL)
      expect(r.deny).toBe('not here')
    }
    const fourth = await $.tool.call(CALL)
    expect(fourth.deny).toContain('loop-breaker')
  })

  test('a try-again-later failure is not a loop', async ($, on) => {
    mock.clock(on)
    emptyBand(on)
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('tool.call', () => ({
      result: 'heavy-job admission deferred: transient pressure: MemAvailable is below required',
      isError: true,
    }))
    await $.session.start(SESSION)

    for (let i = 0; i < 6; i += 1) {
      const r = await $.tool.call(CALL)
      expect(r.deny).toBeUndefined()
      expect(r.context).toBeUndefined()
    }

    const band = await $.ui.mount(BAND)
    expect(await band.find({ type: 'Text', text: /identical failures/ })).toBeUndefined()
    await band.unmount()
  })

  test('a refusal worded as a rate limit is not a loop either', async ($, on) => {
    mock.clock(on)
    emptyBand(on)
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('tool.call', () => ({ deny: 'Rate limit reached, retry after 30 seconds.' }))
    await $.session.start(SESSION)

    for (let i = 0; i < 5; i += 1) {
      const r = await $.tool.call(CALL)
      expect(r.deny).toBe('Rate limit reached, retry after 30 seconds.')
    }
  })

  test('a retry-later word deep in a long error is still a failure', async ($, on) => {
    mock.clock(on)
    emptyBand(on)
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    on('tool.call', () => ({
      result: 'FAIL src/auth.test.ts\n' + 'expected 200 to equal 201\n'.repeat(40) + 'see also status 503 in fixture',
      isError: true,
    }))
    await $.session.start(SESSION)

    for (let i = 0; i < 3; i += 1) await $.tool.call(CALL)
    expect((await $.tool.call(CALL)).deny).toContain('loop-breaker')
  })

  test('the retryLater option replaces the default words', { options: { retryLater: 'flaky network' } }, async ($, on) => {
    mock.clock(on)
    emptyBand(on)
    on('session.start', ($, e) => ({ cwd: e.cwd }))
    let calls = 0
    on('tool.call', () => {
      calls += 1
      return calls <= 3
        ? { result: 'flaky network, please retry', isError: true }
        : { result: 'heavy-job admission deferred', isError: true }
    })
    await $.session.start(SESSION)

    for (let i = 0; i < 3; i += 1) expect((await $.tool.call(CALL)).deny).toBeUndefined()
    // "deferred" no longer matches, so these three count and the fourth is refused.
    await $.tool.call(CALL)
    await $.tool.call(CALL)
    await $.tool.call(CALL)
    expect((await $.tool.call(CALL)).deny).toContain('loop-breaker')
  })

  test('an allowlisted tool is never refused', { options: { allow: 'Bash, Read' } }, async ($, on) => {
    failingWorld(on)
    await $.session.start(SESSION)

    for (let i = 0; i < 6; i += 1) {
      const r = await $.tool.call(CALL)
      expect(r.deny).toBeUndefined()
    }
  })

  test('a lower threshold refuses sooner', { options: { threshold: 2 } }, async ($, on) => {
    failingWorld(on)
    await $.session.start(SESSION)

    const first = await $.tool.call(CALL)
    expect(first.context?.[0]).toContain('failed 1 times')
    await $.tool.call(CALL)
    const third = await $.tool.call(CALL)
    expect(third.deny).toContain('failed 2 times')
  })

  test('the band is quiet until two failures, then shows the face', async ($, on) => {
    failingWorld(on)
    await $.session.start(SESSION)

    const quiet = await $.ui.mount(BAND)
    expect(await quiet.find({ type: 'Text', text: /identical failures/ })).toBeUndefined()
    await quiet.unmount()

    await $.tool.call(CALL)
    await $.tool.call(CALL)

    const uneasy = await $.ui.mount(BAND)
    expect(await uneasy.find({ type: 'Text', text: /2 identical failures/ })).toBeDefined()
    expect(await uneasy.find({ type: 'Text', text: /\(o_o\)/ })).toBeDefined()
    await uneasy.unmount()

    await $.tool.call(CALL)
    await $.tool.call(CALL)

    const broken = await $.ui.mount(BAND)
    expect(await broken.find({ type: 'Text', text: /loop broken: Bash/ })).toBeDefined()
    await broken.press({ key: 'dismiss' })
    expect(await broken.find({ type: 'Text', text: /loop broken/ })).toBeUndefined()
    await broken.unmount()
  })

  test('the band yields to a survey', async ($, on) => {
    failingWorld(on)
    await $.session.start(SESSION)
    await $.tool.call(CALL)
    await $.tool.call(CALL)

    const ui = await $.ui.mount({ ...BAND, props: { ...BAND.props, hasSurvey: true } })
    expect(await ui.find({ type: 'Text', text: /identical failures/ })).toBeUndefined()
    await ui.unmount()
  })
})
