// Local tests for the adopted-agent fixes (not from upstream; see ../NOTICE.md).
import { describe, expect, test } from 'claude-code/testing'

import { duration, elapsed, keep } from '../hooks/register'

const PANE = { component: 'Pane', requestId: 'agent-radar', props: { title: 'Agent Radar', isFocused: true, bodyColumns: 100, placement: 'dock' } }

// Two agents that started before the radar loaded, as the engine lists them.
const BEFORE = [
  { id: 'old-done', description: 'earlier sweep', type: 't', status: 'completed' },
  { id: 'old-run', description: 'live sweep', type: 't', status: 'running' },
]

// Stands for the engine beneath the mod; `listed` is what $.agent.list() answers, given as the
// list itself or as a function of the engine that produces it (so a test can act mid-call).
function engine(on: any, listed: object[] | ((eng: any) => Promise<object[]>) = BEFORE) {
  const toasts: string[] = []
  on('session.start', (_$: any, e: any) => ({ sessionId: 's', cwd: e.cwd }))
  on('command.register', () => ({ value: undefined }))
  on('clock.every', () => ({ value: { cancel: () => {} } }))
  on('agent.list', async (eng: any) => ({ value: typeof listed === 'function' ? await listed(eng) : listed }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.toast', (_$: any, e: any) => (toasts.push(e.text), { value: undefined }))
  on('ui.render', ($: any, e: any) => $.ui.resolve(e).Text({ children: 'band below' }))
  on('session.messages', () => ({ value: [] }))
  return { toasts }
}

const agent = (id: string, status: 'running' | 'done') => ({ id, description: id, type: 't', status, startedAt: 0, tools: 0, last: '' })

describe('agent-radar adopted agents', () => {
  test('an adopted agent shows a lower bound while it runs and no clock once it had already finished', () => {
    const adoptedDone = { status: 'done' as const, startedAt: 1_000, adopted: true }
    expect(duration(adoptedDone, 2_000)).toBe('duration unknown')
    expect(duration(adoptedDone, 2_000 + 3_600_000)).toBe('duration unknown') // an hour later: unchanged
    // Adopted and running: its clock started at adoption, so the time shown is a lower bound.
    expect(duration({ status: 'running' as const, startedAt: 0, adopted: true }, 9_000)).toBe('9s+')
    // Adopted, then finished under the radar's watch: still a lower bound, and it stops.
    expect(duration({ status: 'done' as const, startedAt: 0, endedAt: 9_000, adopted: true }, 90_000)).toBe('9s+')
    // Spawned agents keep the real clock.
    expect(duration({ status: 'done' as const, startedAt: 0, endedAt: 9_000 })).toBe('9s')
    expect(duration({ status: 'running' as const, startedAt: 0 }, 9_000)).toBe('9s')
    expect(elapsed({ startedAt: 0, endedAt: 9_000 })).toBe('9s')
  })

  test('/radar adopts engine agents; the pane shows no clock for the finished one and a lower bound for the running one', async ($, on) => {
    engine(on)
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)

    const r = await $.command.run({ command: 'radar', args: '' } as any)
    expect(r.text).toBe('1 running, 1 finished')

    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.find({ type: 'Text', text: /1 running · 1 finished/ })).toBeDefined()
    expect(await ui.find({ key: 'agent-old-done' })).toBeDefined()

    await ui.press({ key: 'agent-old-done' })
    expect(await ui.find({ type: 'Text', text: /duration unknown · 0 tools/ })).toBeDefined()
    await ui.press({ key: 'back' })

    await ui.press({ key: 'agent-old-run' })
    expect(await ui.find({ type: 'Text', text: /duration unknown/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /\d+s\+ · 0 tools/ })).toBeDefined() // running since before the radar: a lower bound
    await ui.unmount()
  })

  test('Clear finished stays cleared: the next /radar does not import those agents again', async ($, on) => {
    // The engine's list also carries the agent this session spawns, finished, as it would.
    engine(on, [...BEFORE, { id: 'a1', description: 'sweep runner', type: 'general-purpose', status: 'completed' }])
    on('agent.spawn', () => ({ model: 'sonnet', agentId: 'a1' }))
    on('turn.complete', () => ({ text: '' }))
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    await $.agent.spawn({ prompt: 'run it', description: 'sweep runner' } as any)
    await $.turn.complete({ reason: 'answer', answer: 'done', durationMs: 1, agentId: 'a1' } as any)

    expect((await $.command.run({ command: 'radar', args: '' } as any)).text).toBe('1 running, 2 finished')

    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.find({ key: 'agent-a1' })).toBeDefined()
    await ui.press({ key: 'clear' })
    expect(await ui.find({ key: 'agent-old-done' })).toBeUndefined()
    expect(await ui.find({ key: 'agent-a1' })).toBeUndefined()
    expect(await ui.find({ key: 'agent-old-run' })).toBeDefined()

    // Reopening the radar adopts from the engine's list again: the cleared agents stay cleared.
    expect((await $.command.run({ command: 'radar', args: '' } as any)).text).toBe('1 running, 0 finished')
    expect(await ui.find({ type: 'Text', text: /1 running · 0 finished/ })).toBeDefined()
    expect(await ui.find({ key: 'agent-old-done' })).toBeUndefined()
    expect(await ui.find({ key: 'agent-a1' })).toBeUndefined()
    await ui.unmount()
  })

  test('keep() drops the oldest finished agents past the cap and never a running one', () => {
    const finished = Array.from({ length: 31 }, (_, i) => agent(`f${i}`, 'done'))
    const kept = keep([...finished, agent('long', 'running')])
    expect(kept.length).toBe(31)
    expect(kept.some(a => a.id === 'long')).toBe(true)
    expect(kept.some(a => a.id === 'f30')).toBe(false) // the 31st finished one, oldest in list order
    expect(keep([agent('a', 'running'), agent('b', 'done')]).length).toBe(2) // under the cap: unchanged
  })

  test('a running agent outlives 31 later spawns and its completion still reaches the radar', async ($, on) => {
    const { toasts } = engine(on, [])
    let n = 0
    on('agent.spawn', () => ({ model: 'sonnet', agentId: `a${++n}` }))
    on('turn.complete', () => ({ text: '' }))
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    await $.agent.spawn({ prompt: 'long', description: 'long sweep' } as any) // a1, still running
    for (let i = 0; i < 31; i++) {
      await $.agent.spawn({ prompt: 'short', description: `short ${i}` } as any)
      await $.turn.complete({ reason: 'answer', answer: 'done', durationMs: 1, agentId: `a${n}` } as any)
    }
    // The next spawn applies the cap: the oldest finished one goes, both running ones stay.
    await $.agent.spawn({ prompt: 'long', description: 'second sweep' } as any)
    expect((await $.command.run({ command: 'radar', args: '' } as any)).text).toBe('2 running, 30 finished')

    await $.turn.complete({ reason: 'answer', answer: 'done', durationMs: 1, agentId: 'a1' } as any)
    expect(toasts.some(t => t.startsWith('✓ long sweep done'))).toBe(true)
    expect((await $.command.run({ command: 'radar', args: '' } as any)).text?.startsWith('1 running')).toBe(true)
  })

  test('an agent that spawns while /radar is adopting gets one row, not two', async ($, on) => {
    // The engine's list call is held open until the test releases it; the spawn lands meanwhile,
    // and the list then names that agent too.
    let entered!: () => void
    let release!: () => void
    const listCalled = new Promise<void>(r => { entered = r })
    const gate = new Promise<void>(r => { release = r })
    engine(on, async () => {
      entered()
      await gate
      return [{ id: 'a1', description: 'sweep runner', type: 'general-purpose', status: 'running' }]
    })
    on('agent.spawn', () => ({ model: 'sonnet', agentId: 'a1' }))
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)

    const radar = $.command.run({ command: 'radar', args: '' } as any)
    await listCalled
    await $.agent.spawn({ prompt: 'run it', description: 'sweep runner' } as any)
    release()
    expect((await radar).text).toBe('1 running, 0 finished')

    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.find({ type: 'Text', text: /1 running · 0 finished/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /duration unknown/ })).toBeUndefined() // the spawned row won, with its real clock
    await ui.unmount()
  })
})
