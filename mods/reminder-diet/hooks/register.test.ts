import type { On, SessionMessage } from 'claude-code'
import { describe, expect, test } from 'claude-code/testing'

import { MAX_LOOPS } from './register'

const ENGINE = { kind: 'engine' } as const
const NAG = "The task tools haven't been used recently. If you're working on tasks that would benefit from tracking progress, consider using TaskCreate."
const WITH_LIST = `${NAG}\n\nHere are the existing tasks:\n\n#1. [in_progress] Write the mod`
const CHANGED_LIST = `${NAG}\n\nHere are the existing tasks:\n\n#1. [completed] Write the mod`
/** A conversation to compact, and what a compaction leaves: the engine refuses an empty one. */
const TALK: SessionMessage[] = [{ role: 'user', text: 'Write the mod.', toolUses: [] }]
const SUMMARY: SessionMessage[] = [{ role: 'user', text: 'Summary: the mod is written.', toolUses: [] }]

/**
 * The engine beneath the mod: an attachment is rendered as its own text (or,
 * with `render`, as that function makes it), a compaction is answered with
 * `compact` (`skip-spelled` is a skip that names `messages: undefined`, which
 * the skip's type allows), the context blocks come back as asked, and an
 * ending is echoed as core echoes it.
 */
function engine(
  on: On,
  opts: { render?: (text: string, type: string) => string | null; compact?: 'done' | 'skip' | 'skip-spelled' } = {},
) {
  on('prompt.attachment', (_$, e) => ({ text: opts.render ? opts.render(e.text, e.type) : e.text }))
  on('session.compact', () =>
    opts.compact === 'skip'
      ? { skip: 'kept' }
      : opts.compact === 'skip-spelled'
        ? { skip: 'kept', messages: undefined }
        : { messages: SUMMARY },
  )
  on('prompt.context', (_$, e) => ({ blocks: e.blocks }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
}

describe('prompt.attachment', () => {
  test('a task reminder identical to the last one the loop was sent is left out', async ($, on) => {
    engine(on)
    const send = (text: string) => $.prompt.attachment({ type: 'task_reminder', text, origin: ENGINE })
    expect((await send(NAG)).text).toBe(NAG) // the loop's first passes through
    expect((await send(NAG)).text).toBeNull() // the exact repeat is left out
    expect((await send(NAG)).text).toBeNull()
    expect((await send(WITH_LIST)).text).toBe(WITH_LIST) // a changed reminder passes
    expect((await send(CHANGED_LIST)).text).toBe(CHANGED_LIST)
    expect((await send(CHANGED_LIST)).text).toBeNull()
    // Compared with the last one sent, not with any one sent: the model's latest copy is CHANGED_LIST.
    expect((await send(WITH_LIST)).text).toBe(WITH_LIST)
  })

  test('the engine docs name the reminder todo_reminder, and that name is handled the same way', async ($, on) => {
    engine(on)
    const send = () => $.prompt.attachment({ type: 'todo_reminder', text: NAG, origin: ENGINE })
    expect((await send()).text).toBe(NAG)
    expect((await send()).text).toBeNull()
  })

  test('each loop is compared with its own last reminder', async ($, on) => {
    engine(on)
    const send = (agentId?: string) =>
      $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE, ...(agentId ? { agentId } : {}) })
    expect((await send()).text).toBe(NAG)
    expect((await send('sub-1')).text).toBe(NAG) // a subagent's first, though main was sent the same text
    expect((await send('sub-2')).text).toBe(NAG)
    expect((await send('sub-1')).text).toBeNull()
    expect((await send()).text).toBeNull()
  })

  test('other attachments pass through untouched, however often they repeat', async ($, on) => {
    engine(on)
    const nudge = "The user hasn't heard from you in a while."
    for (const type of ['silent_turn_reminder', 'batching_reminder_sent', 'instructions']) {
      for (let i = 0; i < 3; i++) {
        expect((await $.prompt.attachment({ type, text: nudge, origin: ENGINE })).text).toBe(nudge)
      }
    }
  })

  test('the comparison is on the text as rendered beneath, not the text the event arrived with', async ($, on) => {
    let turn = 0
    engine(on, { render: (text) => `${text} (turn ${++turn})` })
    const send = () => $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE })
    // Same input text, but the rendering differs each time: nothing is a repeat.
    expect((await send()).text).toBe(`${NAG} (turn 1)`)
    expect((await send()).text).toBe(`${NAG} (turn 2)`)
  })

  test('two reminders rendered the same beneath are a repeat, though they arrived different', async ($, on) => {
    engine(on, { render: (text) => text.replace(/ \(turn \d+\)$/, '') }) // a plugin beneath strips a counter
    const send = (turn: number) => $.prompt.attachment({ type: 'task_reminder', text: `${NAG} (turn ${turn})`, origin: ENGINE })
    expect((await send(1)).text).toBe(NAG)
    expect((await send(2)).text).toBeNull() // the model would read NAG twice
  })

  test('a reminder left out beneath is not remembered, so the next one is the first the model sees', async ($, on) => {
    let drop = true
    engine(on, { render: (text) => (drop ? null : text) })
    const send = () => $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE })
    expect((await send()).text).toBeNull()
    drop = false
    expect((await send()).text).toBe(NAG)
    expect((await send()).text).toBeNull()
  })

  test(`past ${MAX_LOOPS} loops the least recently reminded is forgotten, and its next reminder passes`, async ($, on) => {
    engine(on)
    const send = (agentId: string) => $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE, agentId })
    for (let i = 0; i <= MAX_LOOPS; i++) expect((await send(`sub-${i}`)).text).toBe(NAG)
    expect((await send(`sub-${MAX_LOOPS}`)).text).toBeNull() // the newest is still held
    expect((await send('sub-1')).text).toBeNull() // still held: only sub-0 fell off
    expect((await send('sub-0')).text).toBe(NAG) // forgotten, so it passes once more
  })

  test('a repeat counts as being reminded, so a loop that keeps repeating is not the one forgotten', async ($, on) => {
    engine(on)
    const send = (agentId: string) => $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE, agentId })
    expect((await send('busy')).text).toBe(NAG)
    for (let i = 0; i < MAX_LOOPS - 1; i++) expect((await send(`idle-${i}`)).text).toBe(NAG) // 256 loops held
    expect((await send('busy')).text).toBeNull() // a repeat, left out: busy is now the most recently reminded
    expect((await send('new')).text).toBe(NAG) // one loop too many: the least recently reminded falls off
    expect((await send('busy')).text).toBeNull() // still held
    expect((await send('idle-0')).text).toBe(NAG) // idle-0 was the one forgotten
  })
})

describe('starting over', () => {
  test("a loop's compaction drops the earlier copy, so its next reminder passes", async ($, on) => {
    engine(on)
    const send = (agentId?: string) =>
      $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE, ...(agentId ? { agentId } : {}) })
    expect((await send()).text).toBe(NAG)
    expect((await send('sub-1')).text).toBe(NAG)
    await $.session.compact({ trigger: 'auto', messages: TALK })
    expect((await send()).text).toBe(NAG) // main compacted: sent again
    expect((await send('sub-1')).text).toBeNull() // the subagent's context still has its copy
    await $.session.compact({ trigger: 'manual', agentId: 'sub-1', messages: TALK })
    expect((await send('sub-1')).text).toBe(NAG)
    expect((await send()).text).toBeNull()
  })

  test('a precomputed summary does not start over: the conversation is still whole', async ($, on) => {
    engine(on)
    const send = () => $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE })
    expect((await send()).text).toBe(NAG)
    await $.session.compact({ trigger: 'precompute', messages: TALK })
    expect((await send()).text).toBeNull()
  })

  test('a skipped compaction does not start over', async ($, on) => {
    engine(on, { compact: 'skip' })
    const send = () => $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE })
    expect((await send()).text).toBe(NAG)
    const result = await $.session.compact({ trigger: 'auto', messages: TALK })
    expect('skip' in result).toBe(true) // precondition: the compaction was skipped
    expect((await send()).text).toBeNull()
  })

  test('a skip that names messages as undefined is still a skip', async ($, on) => {
    engine(on, { compact: 'skip-spelled' })
    const send = () => $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE })
    expect((await send()).text).toBe(NAG)
    const result = await $.session.compact({ trigger: 'auto', messages: TALK })
    expect('skip' in result && 'messages' in result).toBe(true) // precondition: the key arrives, set to undefined
    expect((await send()).text).toBeNull()
  })

  test("a fresh context (/clear) starts main over and leaves subagents' loops alone", async ($, on) => {
    engine(on)
    const send = (agentId?: string) =>
      $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE, ...(agentId ? { agentId } : {}) })
    expect((await send()).text).toBe(NAG)
    expect((await send('sub-1')).text).toBe(NAG)
    await $.prompt.context({ blocks: [] })
    expect((await send()).text).toBe(NAG)
    expect((await send('sub-1')).text).toBeNull()
  })

  test("a resume starts every loop over: the resumed conversation's context never had the earlier copies", async ($, on) => {
    engine(on)
    const send = (agentId?: string) =>
      $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE, ...(agentId ? { agentId } : {}) })
    expect((await send()).text).toBe(NAG)
    expect((await send('sub-1')).text).toBe(NAG)
    await $.session.end({ reason: 'resume', sessionId: 'ended', resume: { id: 'ended' } })
    expect((await send()).text).toBe(NAG) // the resumed conversation's first reminder, though the ended one's last matched it
    expect((await send('sub-1')).text).toBe(NAG)
    expect((await send()).text).toBeNull() // and from there it is compared as before
  })

  test('an ending for any other reason leaves the loops alone', async ($, on) => {
    engine(on)
    const send = () => $.prompt.attachment({ type: 'task_reminder', text: NAG, origin: ENGINE })
    expect((await send()).text).toBe(NAG)
    await $.session.end({ reason: 'other', sessionId: 'ended', resume: { id: 'ended' } })
    expect((await send()).text).toBeNull()
  })
})
