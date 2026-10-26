import { describe, expect, test } from 'claude-code/testing'

import { parse } from './register'

const SESSION = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const
const USAGE = { input_tokens: 40, output_tokens: 300, cache_read_input_tokens: 50000, cache_creation_input_tokens: 1200 }
const NO_USAGE = { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }

const BAND = {
  plugin: 'lookout',
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

const run = (args: string) =>
  ({
    command: 'lookout',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 120 },
  }) as const

const wait = () => new Promise(done => (globalThis as any).setTimeout(done, 10))

/** A /clear or a resume: the conversation ends and the process goes on under another. */
const ended = (reason: 'clear' | 'resume') => ({ reason, sessionId: 's', resume: { id: 's' } }) as const

type Reply = string | Record<string, unknown> | Promise<string>
type Surfaces = string[] | Promise<string[]>

/**
 * Stands for the engine beneath the mod: `surfaces` is what draws the session (`draw` changes
 * it), `stored` is the mod's store, kept across sessions, whose `broken` calls go unanswered and
 * so reject, as the engine's bottom hook does, and each fork answers the next of `replies` (a
 * string is the reply's text), `none` once they run out.
 */
function world(
  on: any,
  {
    surfaces = ['terminal'] as Surfaces,
    replies = [] as Reply[],
    stored = new Map<string, unknown>(),
    broken = [] as Array<'get' | 'set' | 'delete'>,
  } = {},
) {
  const prompts: string[] = []
  let drawn = surfaces
  if (!broken.includes('get')) on('store.get', (_$: any, e: any) => ({ value: stored.get(e.key) }))
  if (!broken.includes('set')) on('store.set', (_$: any, e: any) => ({ value: void stored.set(e.key, e.value) }))
  if (!broken.includes('delete')) on('store.delete', (_$: any, e: any) => ({ value: void stored.delete(e.key) }))
  on('session.start', (_$: any, e: any) => ({ sessionId: 's', cwd: e.cwd }))
  on('session.end', (_$: any, e: any) => ({ sessionId: e.sessionId }))
  on('command.register', () => ({ value: undefined }))
  on('prompt.submit', () => ({ text: '' }))
  on('session.surfaces', async () => ({ value: await drawn }))
  on('model.fork', async (_$: any, e: any) => {
    prompts.push(e.prompt)
    const reply = await (replies.shift() ?? 'none')
    return { value: typeof reply === 'string' ? { isAnswered: true, text: reply, usage: USAGE } : reply }
  })
  on('turn.step', async function* (_$: any, e: any) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'tool_use', usage: null }
  })
  // Beneath the mod nothing draws in the band: an empty Box, as the engine's own band is empty.
  on('ui.render', ($: any, e: any) => {
    const { Box } = $.ui.resolve(e)
    return Box({ children: [] })
  })
  return { forks: () => prompts.length, prompts, draw: (next: Surfaces) => (drawn = next) }
}

/**
 * Holds the first write of a flag to the card until `release`, so a test can land something
 * between the check's read of the card and its write, the window `update` retries over.
 */
function holdFirstFlagWrite(on: any) {
  let isHeld = false
  let release = () => {}
  const gate = new Promise<void>(done => (release = done))
  on('state.set', async (_$: any, e: any, next: any) => {
    if (e.value !== null && !isHeld) {
      isHeld = true
      await gate
    }
    return next(e)
  })
  return { isHeld: () => isHeld, release: () => release() }
}

/** Runs `n` model steps to their end, on the main thread or in the subagent `agentId`. */
async function steps($: any, n: number, agentId?: string) {
  for (let i = 0; i < n; i++) {
    const stream = $.turn.step({
      turnId: 't1',
      index: i,
      model: 'claude-opus-5-5',
      messageCount: 4,
      ...(agentId ? { agentId } : {}),
    })
    for await (const _chunk of stream) {
      // drained: the step's pieces are not what these tests read
    }
    await stream.result
    await wait()
  }
}

/** Whether the band, drawn now, shows a lookout flag matching `text`. */
async function shows($: any, text: RegExp = /./): Promise<boolean> {
  const band = await $.ui.mount(BAND)
  const flag = await band.find({ type: 'Text', text: /✦ lookout/ })
  const match = await band.find({ type: 'Text', text })
  await band.unmount()
  return flag !== undefined && match !== undefined
}

describe('lookout checks', () => {
  test('no fork while nothing draws the session', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await steps($, 6)
    expect(w.forks()).toBe(1)
    w.draw([])
    await steps($, 12)
    expect(w.forks()).toBe(1)
  })

  test('one fork every six main-thread steps while something draws the session', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await steps($, 5)
    expect(w.forks()).toBe(0)
    await steps($, 7)
    expect(w.forks()).toBe(2)
  })

  test('a subagent step is not counted', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await steps($, 12, 'agent-1')
    expect(w.forks()).toBe(0)
    await steps($, 6)
    expect(w.forks()).toBe(1)
  })

  test('the every option sets the cadence', { options: { every: 2 } }, async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await steps($, 6)
    expect(w.forks()).toBe(3)
  })

  test('every 0 turns the automatic checks off', { options: { every: 0 } }, async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await steps($, 12)
    expect(w.forks()).toBe(0)
    await $.command.run(run('now'))
    await wait()
    expect(w.forks()).toBe(1)
  })

  test('a check still running is not doubled', { options: { every: 1 } }, async ($, on) => {
    let release: (text: string) => void = () => {}
    const slow = new Promise<string>(done => (release = done))
    const w = world(on, { replies: [slow] })
    await $.session.start(SESSION)
    await steps($, 5)
    expect(w.forks()).toBe(1)
    release('none')
    await wait()
    await steps($, 1)
    expect(w.forks()).toBe(2)
  })
})

describe('lookout band', () => {
  test('a flag shows above the prompt and ok dismisses it', { options: { every: 1 } }, async ($, on) => {
    world(on, { replies: ['Lookout: the test suite was skipped, not passed'] })
    await $.session.start(SESSION)
    expect(await shows($)).toBe(false)

    await steps($, 1)
    const band = await $.ui.mount(BAND)
    expect(await band.find({ type: 'Text', text: /the test suite was skipped, not passed/ })).toBeDefined()
    await band.press({ key: 'dismiss' })
    expect(await band.find({ type: 'Text', text: /skipped/ })).toBeUndefined()
    await band.unmount()
  })

  test('none, a failed fork and a reply in the wrong shape show nothing', { options: { every: 1 } }, async ($, on) => {
    const w = world(on, {
      replies: [
        'none',
        { isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: NO_USAGE },
        'Sure, carrying on with the migration now.',
        { isAnswered: false, reason: 'nothing-to-fork' },
        { isAnswered: false, reason: 'empty-reply', usage: NO_USAGE },
      ],
    })
    await $.session.start(SESSION)
    await steps($, 5)
    expect(w.forks()).toBe(5)
    expect(await shows($)).toBe(false)
  })

  test('a flag stays for one more prompt and clears on the second', { options: { every: 1 } }, async ($, on) => {
    world(on, { replies: ['Lookout: the deploy step was never run'] })
    await $.session.start(SESSION)
    await steps($, 1)
    await $.prompt.submit({ text: 'go on' } as any)
    expect(await shows($, /deploy step/)).toBe(true)
    await $.prompt.submit({ text: 'and then?' } as any)
    expect(await shows($)).toBe(false)
  })

  test('a flag already shown is not shown again, and the next check is told about it', { options: { every: 1 } }, async ($, on) => {
    const w = world(on, { replies: ['Lookout: it pushed straight to main', 'Lookout: It pushed straight to main.'] })
    await $.session.start(SESSION)
    await steps($, 1)
    const band = await $.ui.mount(BAND)
    await band.press({ key: 'dismiss' })
    await band.unmount()

    await steps($, 1)
    expect(w.forks()).toBe(2)
    expect(w.prompts[1]).toContain('it pushed straight to main')
    expect(await shows($)).toBe(false)
  })

  test('two different flags in a non-Latin script are both shown', { options: { every: 1 } }, async ($, on) => {
    world(on, { replies: ['Lookout: 迁移失败了', 'Lookout: 测试被跳过'] })
    await $.session.start(SESSION)
    await steps($, 1)
    expect(await shows($, /迁移失败了/)).toBe(true)
    await steps($, 1)
    expect(await shows($, /测试被跳过/)).toBe(true)
  })

  test('the band yields to a survey', { options: { every: 1 } }, async ($, on) => {
    world(on, { replies: ['Lookout: something'] })
    await $.session.start(SESSION)
    await steps($, 1)
    const band = await $.ui.mount({ ...BAND, props: { ...BAND.props, hasSurvey: true } })
    expect(await band.find({ type: 'Text', text: /something/ })).toBeUndefined()
    await band.unmount()
  })
})

describe('/lookout', () => {
  test('off stops the checks and on resumes them', { options: { every: 1 } }, async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    const off = await $.command.run(run('off'))
    expect(off.text).toMatch(/off/)
    await steps($, 3)
    expect(w.forks()).toBe(0)

    await $.command.run(run('on'))
    await steps($, 1)
    expect(w.forks()).toBe(1)
  })

  test('off clears a flag on screen', { options: { every: 1 } }, async ($, on) => {
    world(on, { replies: ['Lookout: a flag'] })
    await $.session.start(SESSION)
    await steps($, 1)
    await $.command.run(run('off'))
    expect(await shows($)).toBe(false)
  })

  test('now asks at once, and the status reports what came back and what it cost', { options: { every: 0 } }, async ($, on) => {
    const w = world(on, { replies: ['Lookout: the lockfile changed but install never ran'] })
    await $.session.start(SESSION)
    await $.command.run(run('now'))
    await wait()
    expect(w.forks()).toBe(1)
    expect(await shows($, /lockfile changed/)).toBe(true)

    const { text } = await $.command.run(run(''))
    expect(text).toMatch(/automatic checks off/)
    expect(text).toMatch(/last check: flagged/)
    expect(text).toMatch(/checks this session: 1/)
    expect(text).toMatch(/cache read 50,000/)
    expect(text).toMatch(/cache write 1,200/)
    expect(text).toMatch(/lockfile changed/)
  })

  test('off from an earlier session holds in the next, and on lifts it', { options: { every: 1 } }, async ($, on) => {
    const stored = new Map<string, unknown>([['off', true]])
    const w = world(on, { stored })
    await $.session.start(SESSION)
    await steps($, 3)
    expect(w.forks()).toBe(0)
    expect((await $.command.run(run(''))).text).toMatch(/lookout: off/)

    await $.command.run(run('on'))
    expect(stored.has('off')).toBe(false)
    await steps($, 1)
    expect(w.forks()).toBe(1)
  })

  test('off is kept for later sessions', async ($, on) => {
    const stored = new Map<string, unknown>()
    world(on, { stored })
    await $.session.start(SESSION)
    await $.command.run(run('off'))
    expect(stored.get('off')).toBe(true)
  })

  test('an off that cannot be saved holds in this session and says later ones may check', { options: { every: 1 } }, async ($, on) => {
    const w = world(on, { broken: ['set'] })
    await $.session.start(SESSION)
    const { text } = await $.command.run(run('off'))
    expect(text).not.toMatch(/later ones/)
    expect(text).toMatch(/could not be saved \([^)]*store\.set[^)]*\)/)
    expect(text).toMatch(/later session may start with it on/)
    await steps($, 3)
    expect(w.forks()).toBe(0)
    expect((await $.command.run(run(''))).text).toMatch(/on\/off setting: .*could not be saved/)
  })

  test('an on that cannot be saved holds in this session and says later ones may stay off', { options: { every: 1 } }, async ($, on) => {
    const w = world(on, { stored: new Map<string, unknown>([['off', true]]), broken: ['delete'] })
    await $.session.start(SESSION)
    const { text } = await $.command.run(run('on'))
    expect(text).toMatch(/on in this session/)
    expect(text).toMatch(/could not be saved/)
    expect(text).toMatch(/later session may still start with it off/)
    await steps($, 1)
    expect(w.forks()).toBe(1)
    expect((await $.command.run(run(''))).text).toMatch(/on\/off setting: .*could not be saved/)
  })

  test('an off setting that cannot be read at start sends no check, and the status says why', { options: { every: 1 } }, async ($, on) => {
    const w = world(on, { broken: ['get'] })
    await $.session.start(SESSION)
    await steps($, 3)
    expect(w.forks()).toBe(0)
    const { text } = await $.command.run(run(''))
    expect(text).toMatch(/lookout: off/)
    expect(text).toMatch(/on\/off setting: .*could not be read \([^)]*store\.get[^)]*\)/)

    await $.command.run(run('on'))
    await steps($, 1)
    expect(w.forks()).toBe(1)
    expect((await $.command.run(run(''))).text).not.toMatch(/on\/off setting/)
  })

  test('off while a check waits to learn what draws the session sends no fork', { options: { every: 1 } }, async ($, on) => {
    let draw = (_surfaces: string[]) => {}
    const w = world(on, { surfaces: new Promise<string[]>(done => (draw = done)) })
    await $.session.start(SESSION)
    await steps($, 1)
    await $.command.run(run('off'))
    draw(['terminal'])
    await wait()
    expect(w.forks()).toBe(0)
  })

  test('a check out before off and then on is not shown', { options: { every: 1 } }, async ($, on) => {
    let answer = (_text: string) => {}
    const late = new Promise<string>(done => (answer = done))
    world(on, { replies: [late] })
    await $.session.start(SESSION)
    await steps($, 1)
    await $.command.run(run('off'))
    await $.command.run(run('on'))
    answer('Lookout: a stale flag')
    await wait()
    expect(await shows($)).toBe(false)
    const { text } = await $.command.run(run(''))
    expect(text).toMatch(/last check: .*turned off/)
  })

  test('a flag that comes back after off is not shown, and the status says why', { options: { every: 1 } }, async ($, on) => {
    let answer = (_text: string) => {}
    const late = new Promise<string>(done => (answer = done))
    world(on, { replies: [late] })
    await $.session.start(SESSION)
    await steps($, 1)
    await $.command.run(run('off'))
    answer('Lookout: a late flag')
    await wait()
    expect(await shows($)).toBe(false)
    const { text } = await $.command.run(run(''))
    expect(text).toMatch(/last check: .*turned off/)
  })

  test('a flag whose card write is out when off lands is not shown after it', { options: { every: 1 } }, async ($, on) => {
    const held = holdFirstFlagWrite(on)
    world(on, { replies: ['Lookout: a flag from before off'] })
    await $.session.start(SESSION)
    await steps($, 1)
    expect(held.isHeld()).toBe(true)
    await $.command.run(run('off'))
    held.release()
    await wait()
    expect(await shows($)).toBe(false)
  })

  test('now while a check is out says so and sends no second one', { options: { every: 0 } }, async ($, on) => {
    let answer = (_text: string) => {}
    const late = new Promise<string>(done => (answer = done))
    const w = world(on, { replies: [late] })
    await $.session.start(SESSION)
    await $.command.run(run('now'))
    await wait()
    const { text } = await $.command.run(run('now'))
    expect(text).toMatch(/already/)
    expect(w.forks()).toBe(1)
    answer('none')
    await wait()
  })

  test('now while off says so and sends no check', async ($, on) => {
    const w = world(on, { replies: ['Lookout: a flag'] })
    await $.session.start(SESSION)
    await $.command.run(run('off'))
    const { text } = await $.command.run(run('now'))
    await wait()
    expect(text).toMatch(/off/)
    expect(text).toMatch(/\/lookout on/)
    expect(w.forks()).toBe(0)
  })

  test('an unknown argument says what the command takes', async ($, on) => {
    world(on)
    await $.session.start(SESSION)
    const { text } = await $.command.run(run('loud'))
    expect(text).toMatch(/\/lookout now/)
    expect(text).toMatch(/\/lookout off/)
  })
})

// pro-gate round 4 P2: what lookout kept of one conversation outlived a /clear or a resume, which
// go on in the same process with no session.start.
describe('a new conversation in the same process', () => {
  test('after a /clear the same flag shows again, and the next check is not told about the old one', { options: { every: 1 } }, async ($, on) => {
    const w = world(on, { replies: ['Lookout: it pushed straight to main', 'Lookout: it pushed straight to main'] })
    await $.session.start(SESSION)
    await steps($, 1)
    const band = await $.ui.mount(BAND)
    await band.press({ key: 'dismiss' })
    await band.unmount()

    await $.session.end(ended('clear'))
    await steps($, 1)
    expect(w.forks()).toBe(2)
    expect(w.prompts[1]).not.toContain('pushed straight to main')
    expect(await shows($, /pushed straight to main/)).toBe(true)
    expect((await $.command.run(run(''))).text).toMatch(/flags this session:\n- it pushed straight to main$/)
  })

  test('a /clear takes the flag on screen with it', { options: { every: 1 } }, async ($, on) => {
    world(on, { replies: ['Lookout: the old conversation skipped its tests'] })
    await $.session.start(SESSION)
    await steps($, 1)
    expect(await shows($, /skipped its tests/)).toBe(true)
    await $.session.end(ended('clear'))
    expect(await shows($)).toBe(false)
  })

  test('a check out at a resume shows nothing and counts nothing in the conversation after it', { options: { every: 1 } }, async ($, on) => {
    let answer = (_text: string) => {}
    const late = new Promise<string>(done => (answer = done))
    world(on, { replies: [late] })
    await $.session.start(SESSION)
    await steps($, 1)
    await $.session.end(ended('resume'))
    answer('Lookout: a flag about the conversation that ended')
    await wait()
    expect(await shows($)).toBe(false)
    const { text } = await $.command.run(run(''))
    expect(text).toMatch(/last check: none yet/)
    expect(text).toMatch(/checks this session: 0 /)
    expect(text).not.toMatch(/flags this session/)
  })

  test('a /clear while a check waits to learn what draws the session sends no fork', { options: { every: 1 } }, async ($, on) => {
    let draw = (_surfaces: string[]) => {}
    const w = world(on, { surfaces: new Promise<string[]>(done => (draw = done)) })
    await $.session.start(SESSION)
    await steps($, 1)
    await $.session.end(ended('clear'))
    draw(['terminal'])
    await wait()
    expect(w.forks()).toBe(0)
  })

  test('a flag whose card write is out when a /clear lands is not shown after it', { options: { every: 1 } }, async ($, on) => {
    const held = holdFirstFlagWrite(on)
    world(on, { replies: ['Lookout: a flag from the conversation that ended'] })
    await $.session.start(SESSION)
    await steps($, 1)
    expect(held.isHeld()).toBe(true)
    await $.session.end(ended('clear'))
    held.release()
    await wait()
    expect(await shows($)).toBe(false)
  })

  test('a check that fails after a /clear leaves the status of the conversation after it alone', { options: { every: 1 } }, async ($, on) => {
    let fail = (_error: Error) => {}
    const late = new Promise<string>((_done, reject) => (fail = reject))
    world(on, { replies: [late] })
    await $.session.start(SESSION)
    await steps($, 1)
    await $.session.end(ended('clear'))
    fail(new Error('the fork was cut off'))
    await wait()
    expect((await $.command.run(run(''))).text).toMatch(/last check: none yet/)
  })

  test('a resume starts the step count and the check totals over', { options: { every: 3 } }, async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await steps($, 5)
    expect(w.forks()).toBe(1)
    expect((await $.command.run(run(''))).text).toMatch(/checks this session: 1 /)

    await $.session.end(ended('resume'))
    expect((await $.command.run(run(''))).text).toMatch(/checks this session: 0 /)
    await steps($, 2)
    expect(w.forks()).toBe(1)
    await steps($, 1)
    expect(w.forks()).toBe(2)
  })

  test('off holds across a /clear', { options: { every: 1 } }, async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await $.command.run(run('off'))
    await $.session.end(ended('clear'))
    await steps($, 3)
    expect(w.forks()).toBe(0)
    expect((await $.command.run(run(''))).text).toMatch(/lookout: off/)
  })

  // pro-gate's last review of #1653, open P2 at 126c7323: a check still out when its conversation
  // ended kept the next conversation from checking at all until its fork came back.
  test('a check still out at a /clear does not hold back the conversation after it', { options: { every: 1 } }, async ($, on) => {
    let answer = (_text: string) => {}
    const late = new Promise<string>(done => (answer = done))
    const w = world(on, { replies: [late] })
    await $.session.start(SESSION)
    await steps($, 1)
    await $.session.end(ended('clear'))
    expect((await $.command.run(run('now'))).text).toMatch(/checking now/)
    await wait()
    expect(w.forks()).toBe(2)
    await steps($, 1)
    expect(w.forks()).toBe(3)
    answer('none')
    await wait()
  })

  test("the ended conversation's check, settling late, leaves the next one's check still out", { options: { every: 1 } }, async ($, on) => {
    let answerOld = (_text: string) => {}
    let answerNew = (_text: string) => {}
    const old = new Promise<string>(done => (answerOld = done))
    const current = new Promise<string>(done => (answerNew = done))
    const w = world(on, { replies: [old, current] })
    await $.session.start(SESSION)
    await steps($, 1)
    await $.session.end(ended('resume'))
    await steps($, 1)
    expect(w.forks()).toBe(2)
    answerOld('none')
    await wait()
    expect((await $.command.run(run('now'))).text).toMatch(/already has a check out/)
    expect(w.forks()).toBe(2)
    answerNew('none')
    await wait()
  })
})

describe('parse', () => {
  test('reads the Lookout line wherever it sits', () => {
    expect(parse('Lookout: tests skipped')).toBe('tests skipped')
    expect(parse('`Lookout: tests skipped`')).toBe('tests skipped')
    expect(parse('Looking back over it.\nLookout: tests skipped')).toBe('tests skipped')
    expect(parse('lookout:   tests   skipped  ')).toBe('tests skipped')
  })

  test('none is nothing to show', () => {
    expect(parse('none')).toBeNull()
    expect(parse('None.')).toBeNull()
    expect(parse('Lookout: none')).toBeNull()
  })

  test('anything else is unreadable', () => {
    expect(parse('Sure, carrying on.')).toBeUndefined()
    expect(parse('')).toBeUndefined()
  })

  test('terminal escapes and control characters are removed and a long flag is cut', () => {
    expect(parse('Lookout: a \u001b[31mred\u001b[0m flag\u0007')).toBe('a red flag')
    const long = parse(`Lookout: ${'word '.repeat(100)}`)
    expect(long!.length).toBeLessThanOrEqual(280)
    expect(long!.endsWith('…')).toBe(true)
  })
})
