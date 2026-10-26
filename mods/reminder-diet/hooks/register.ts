import type { Register } from 'claude-code'

/**
 * reminder-diet: a task reminder that repeats, word for word, the last one the
 * same loop was sent is left out of the request.
 *
 * Every few turns in which no task tool ran, Claude Code injects a task
 * reminder ("The task tools haven't been used recently ..."), followed by the
 * current task list when there is one. In this harness's transcripts over the
 * 14 days to 2026-10-04, 19,794 of 27,432 stored task reminders (72%) carried a
 * task list identical to the previous reminder in the same loop: about 241M
 * characters, most of them in long-running loops (one loop got 995). A repeat
 * tells the model nothing the earlier copy in its context does not, and it
 * stays there until the next compaction, which it brings sooner.
 *
 * The hook lets the engine, and any plugin beneath, render the reminder first,
 * then compares that text with the last task reminder the same loop was sent:
 * equal, it answers null and the request leaves the reminder out; different,
 * or the loop's first, it passes through and becomes the one compared against.
 * The engine asks once per attachment and keeps the answer for the process, so
 * a reminder left out stays out of every later request and the prompt cache is
 * not disturbed. The transcript keeps the engine's record either way.
 *
 * The comparison starts over where the model's context loses the earlier copy:
 * a loop's own compaction, for the main conversation a fresh context
 * (`/clear`, which the engine marks by computing the context blocks again),
 * and for every loop a resume (`session.end` with reason `resume`), since the
 * resumed conversation's context never held the ended one's reminders.
 */

/** The names the engine gives its task reminder: `task_reminder` in this build's transcripts, `todo_reminder` in the API's docs. */
export const REMINDER_TYPES: ReadonlySet<string> = new Set(['task_reminder', 'todo_reminder'])
/** The key the main conversation is held under; a subagent's loop is held under its agentId. */
export const MAIN = 'main'
/** Loops remembered at once. Past this the least recently reminded is forgotten, and its next reminder passes through. */
export const MAX_LOOPS = 256

export const register: Register = (on) => {
  /** The text of the last task reminder each loop was sent. Module-level: a reload starts clean, which only lets one repeat through. */
  const last = new Map<string, string>()

  const remember = (loop: string, text: string) => {
    last.delete(loop) // re-inserted, the loop moves to the newest end
    last.set(loop, text)
    if (last.size > MAX_LOOPS) last.delete(last.keys().next().value as string)
  }

  on('prompt.attachment', async (_$, e, next) => {
    if (!REMINDER_TYPES.has(e.type)) return next(e)
    const answer = await next(e)
    if (answer.text === null) return answer // already left out beneath: not sent, so not remembered
    const loop = e.agentId ?? MAIN
    const repeat = last.get(loop) === answer.text
    remember(loop, answer.text) // a repeat is still a reminder: the loop moves to the newest end either way
    return repeat ? { text: null } : answer
  })

  on('session.compact', async (_$, e, next) => {
    const result = await next(e)
    // A precompute only prepares a summary, and a skip keeps the conversation: the earlier copy is still there.
    // A skip may name `messages` as undefined, so the test is the value, not the key.
    if (e.trigger !== 'precompute' && result.messages !== undefined) last.delete(e.agentId ?? MAIN)
    return result
  })

  on('prompt.context', async (_$, e, next) => {
    last.delete(MAIN)
    return next(e)
  })

  on('session.end', async (_$, e, next) => {
    if (e.reason === 'resume') last.clear() // another conversation takes this one's place; the module and its map go on
    return next(e)
  })
}
