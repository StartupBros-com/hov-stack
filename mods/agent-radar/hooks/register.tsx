// Agent Radar: what are my subagents cooking?
//   The band above the prompt has one live line per running subagent: status, time, tool
//   count and what it is doing right now; a finished one shows a check for 30 s. A toast
//   says when each finishes. /radar opens a pane with every agent and its messages.
//   Delegated work this session started outside itself (Codex, a Pro review, CE's peer, a
//   headless Claude) gets a line too, and a toast when its process ends: ./delegates.ts.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { RadarAgent } from '../types'
import { MAX_PS_MS, PS, grepArgv, grepPatterns, judge, ours, parsePs, rowFor, stillRuns, triage, type Delegate, type Proc, type Verdicts } from './delegates'

const PANE = 'agent-radar'
const SHOW_DONE_MS = 30_000 // a finished agent stays in the band this long
const BAND_ROWS = 4
const HISTORY = 30 // finished agents kept in the list; a running one is never dropped
const LOOK_MS = 5_000 // how often the radar looks for delegated work, while anyone watches

// Held by the host, so the radar survives a hot reload of this file.
const agents = atom({ plugin: 'agent-radar', key: 'agents' } as const, [] as RadarAgent[])
const selected = atom({ plugin: 'agent-radar', key: 'selected' } as const, null as string | null)
const now = atom({ plugin: 'agent-radar', key: 'now' } as const, 0)
// Every id the radar has taken in, spawned or adopted, so adopt() imports each once: clearing
// the finished entries, or the 30-entry cap evicting one, must not bring it back.
const seen = atom({ plugin: 'agent-radar', key: 'seen' } as const, [] as string[])
// Every session id the conversation has had in this process: a /clear moves the id, and work
// started before it still carries the old one. A resume starts it over (`forget`).
const sessions = atom({ plugin: 'agent-radar', key: 'sessions' } as const, [] as string[])

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const r = await next(e)
    await $.command.register({ name: 'radar', description: 'Show what each subagent is doing, in the Agent Radar pane' }).catch(() => {}) // a name Claude Code already has is refused: start anyway
    // A clock for the elapsed times, ticking only while something runs.
    $.clock.every(1000, () => {
      void (async () => {
        // A few seconds past the 30 s too, so the redraw that drops a finished line happens.
        if ((await read($, agents)).some(a => isShown(a, Date.now() - 3_000))) await update($, now, () => Date.now())
      })().catch(() => {})
    })
    $.clock.every(LOOK_MS, () => {
      void look($)
    })
    return r
  })

  // A /clear or a resume moves the session id; what the radar keeps across each: `ends`.
  on('session.end', async ($, e, next) => {
    await ends($, e.reason, e.sessionId).catch(() => {})
    return next(e)
  })

  on('agent.spawn', async ($, e, next) => {
    const r = await next(e)
    if (r.agentId) {
      const id = r.agentId
      const one: RadarAgent = { id, description: e.description || e.name || e.subagentType, type: e.subagentType, status: 'running', startedAt: Date.now(), tools: 0, last: 'starting' }
      await update($, seen, ids => (ids.includes(id) ? ids : [...ids, id]))
      await update($, agents, list => keep([one, ...list.filter(a => a.id !== id)]))
    }
    return r
  })

  on('tool.call', async ($, e, next) => {
    if (e.agentId) {
      const id = e.agentId
      const line = describe(e as unknown as Record<string, unknown>)
      await update($, agents, list => list.map(a => (a.id === id ? { ...a, tools: a.tools + 1, last: line } : a)))
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId) {
      const id = e.agentId
      const failed = e.reason === 'error' || e.reason === 'aborted'
      const list = await update($, agents, all =>
        all.map(a => (a.id === id ? { ...a, status: failed ? 'failed' : 'done', endedAt: Date.now(), last: failed ? `stopped: ${e.reason}` : 'finished' } : a)),
      )
      const one = list.find(a => a.id === id)
      if (one) $.ui.toast(`${failed ? '✗' : '✓'} ${one.description} ${failed ? 'failed' : 'done'} (${duration(one)} · ${one.tools} tools)`)
    }
    return r
  })

  on('command.run', { command: 'radar' }, async $ => {
    await adopt($)
    await look($, true)
    await update($, selected, () => null)
    await $.ui.open({ id: PANE, title: 'Agent Radar', focus: true })
    const list = await read($, agents)
    const running = list.filter(a => a.status === 'running').length
    return { text: `${running} running, ${list.length - running} finished` }
  })

  // The band: one live line per running agent, and a ✓ for 30 s once one finishes.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const rest = await next(e) // what other mods and Claude Code draw here stays
    await read($, now) // subscribes the band to the clock
    const shown = (await read($, agents)).filter(a => isShown(a))
    if (e.props.hasSurvey || shown.length === 0) return rest
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        {shown.slice(0, BAND_ROWS).map(a => (
          <Text wrap="truncate-end">
            <Text color={color(a)} bold>{` ${icon(a)} ${a.description}`}</Text>
            <Text dimColor>{`  ${duration(a)} · ${isDelegated(a) ? where(a) : `${a.tools} tools`}`}</Text>
            {a.status === 'running' && !isDelegated(a) && <Text>{` · ${a.last}`}</Text>}
            {a.status === 'failed' && <Text color="red">{` · ${a.last}`}</Text>}
          </Text>
        ))}
        {shown.length > BAND_ROWS && <Text dimColor>{`   +${shown.length - BAND_ROWS} more · /radar`}</Text>}
        {rest}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    await read($, now) // subscribes the pane to the clock
    const list = await read($, agents)
    const pick = await read($, selected)
    const one = list.find(a => a.id === pick)

    // Delegated work has no messages here: what the radar knows is its process.
    if (one && isDelegated(one)) {
      return (
        <Box flexDirection="column">
          <Text>
            <Text color={color(one)} bold>{`${icon(one)} ${one.description}`}</Text>
            <Text dimColor>{`  delegated · ${duration(one)}`}</Text>
          </Text>
          <Text dimColor wrap="truncate-end">{`pid ${one.pid}${one.cwd ? ` in ${one.cwd}` : ''}`}</Text>
          <Text dimColor>
            {one.status === 'running'
              ? 'Running outside this session; the radar looks for it every few seconds while you watch.'
              : 'Its process has ended. How it went is in its own output; the radar sees only that it is gone.'}
          </Text>
          <Box flexDirection="row" gap={1}>
            <Button key="back" label="Back" hotkey="b" variant="primary" onPress={() => update($, selected, () => null)} />
            <Button key="close" label="Close" hotkey="q" role="dismiss" onPress={() => $.ui.close({ id: PANE })} />
          </Box>
        </Box>
      )
    }

    if (one) {
      const found = await $.session.messages({ agentId: one.id })
      const messages = 'deny' in found ? [] : found.slice(-6)
      return (
        <Box flexDirection="column">
          <Text>
            <Text color={color(one)} bold>{`${icon(one)} ${one.description}`}</Text>
            <Text dimColor>{`  ${one.type} · ${duration(one)} · ${one.tools} tools`}</Text>
          </Text>
          <Text dimColor wrap="truncate-end">{`now: ${one.last}`}</Text>
          <Text dimColor>{'─'.repeat(Math.max(10, e.props.bodyColumns - 2))}</Text>
          {messages.length === 0 && <Text dimColor>No messages yet.</Text>}
          {messages.map(m => (
            <Text wrap="truncate-end">
              <Text color={m.role === 'assistant' ? 'cyan' : undefined} bold>{m.role === 'assistant' ? 'agent: ' : 'task:  '}</Text>
              <Text>{m.text.replace(/\s+/g, ' ').slice(0, 400) || '(tool calls)'}</Text>
            </Text>
          ))}
          <Box flexDirection="row" gap={1}>
            <Button key="back" label="Back" hotkey="b" variant="primary" onPress={() => update($, selected, () => null)} />
            <Button key="close" label="Close" hotkey="q" role="dismiss" onPress={() => $.ui.close({ id: PANE })} />
          </Box>
        </Box>
      )
    }

    const running = list.filter(a => a.status === 'running').length
    return (
      <Box flexDirection="column">
        <Text bold>{`${running} running · ${list.length - running} finished`}</Text>
        {list.length === 0 && <Text dimColor>No subagents or delegated work yet this session.</Text>}
        {list.slice(0, 9).map((a, i) => (
          <Button
            key={`agent-${a.id}`}
            plain
            hotkey={String(i + 1)}
            dimColor={a.status !== 'running'}
            label={
              isDelegated(a)
                ? `${icon(a)} ${a.description} · ${duration(a)} · ${where(a)}${a.status === 'running' ? '' : ' · ended'}`
                : `${icon(a)} ${a.description} · ${duration(a)} · ${a.tools} tools${a.status === 'done' ? '' : ` · ${a.last}`}`
            }
            onPress={() => update($, selected, () => a.id)}
          />
        ))}
        {list.length > 9 && <Text dimColor>{`… ${list.length - 9} older`}</Text>}
        <Box flexDirection="row" gap={1}>
          <Button key="clear" label="Clear finished" hotkey="c" onPress={() => update($, agents, all => all.filter(x => x.status === 'running'))} />
          <Button key="close" label="Close" hotkey="q" role="dismiss" onPress={() => $.ui.close({ id: PANE })} />
        </Box>
      </Box>
    )
  })
}

// Agents that started before this mod loaded: take them from the engine's own list, each once.
// Each check runs inside the update it guards, against that value as it is then: a spawn that
// lands while the list call is pending must not give the same agent a second row.
async function adopt($: EngineInterface) {
  const listed = await $.agent.list()
  let fresh: string[] = []
  await update($, seen, had => {
    fresh = listed.map(a => a.id).filter(id => !had.includes(id))
    return fresh.length > 0 ? [...had, ...fresh] : had
  })
  if (fresh.length === 0) return
  const taken = listed
    .filter(a => fresh.includes(a.id))
    .map((a): RadarAgent => ({
      id: a.id,
      description: a.description,
      type: a.type,
      status: a.status === 'running' ? 'running' : a.status === 'completed' ? 'done' : 'failed',
      startedAt: Date.now(),
      tools: 0,
      last: a.status === 'running' ? 'running (started before the radar)' : a.status,
      adopted: true,
    }))
  await update($, agents, list => {
    const have = new Set(list.map(a => a.id))
    return keep([...list, ...taken.filter(a => !have.has(a.id))])
  })
}

// Every running agent, and the first HISTORY finished ones in list order (newest spawned first).
// A running agent is never dropped: its id is in `seen`, so nothing would ever bring it back.
export function keep(list: RadarAgent[]) {
  let finished = 0
  return list.filter(a => a.status === 'running' || finished++ < HISTORY)
}

// Running, or finished in the last 30 s.
export function isShown(a: RadarAgent, at = Date.now()) {
  return a.status === 'running' || (a.endedAt !== undefined && at - a.endedAt < SHOW_DONE_MS)
}

function icon(a: RadarAgent) {
  return a.status === 'running' ? '●' : a.status === 'done' ? '✓' : a.status === 'ended' ? '■' : '✗'
}

function color(a: RadarAgent) {
  return a.status === 'running' ? 'yellow' : a.status === 'done' ? 'green' : a.status === 'ended' ? 'blue' : 'red'
}

// A row for delegated work: the one kind with a process, so the one kind with a pid.
function isDelegated(a: RadarAgent): a is RadarAgent & { pid: number } {
  return a.pid !== undefined
}

// Where delegated work runs: the last part of its directory, or its pid when that is unknown.
function where(a: RadarAgent & { pid: number }) {
  return a.cwd ? a.cwd.slice(a.cwd.lastIndexOf('/') + 1) || a.cwd : `pid ${a.pid}`
}

// Whether anything draws this session. A read that fails counts as watched.
async function isWatched($: EngineInterface) {
  return $.session.surfaces().then(
    s => s.length > 0,
    () => true,
  )
}

// Delegated work: the look in flight, if any; each process judged once (./delegates.ts), and the
// last time each running row was seen, so one that ended while nobody watched ends then. These
// start over when the module reloads; the rows are the host's and stay, matched again by rowFor.
let looking: Promise<boolean> | null = null
const verdicts: Verdicts = new Map()
const lastSeen = new Map<string, number>()
// Every session id the conversation has had in this process, twice over: the host's list
// (`sessions`) outlives a reload of this module, and this one outlives whatever a /clear does to
// the host's values.
const hadIds = new Set<string>()
// The id a resume left, until the session is seen under another (`arrive`).
let left: string | null = null

async function remember($: EngineInterface, id: string) {
  hadIds.add(id)
  return update($, sessions, had => (had.includes(id) ? had : [...had, id]))
}

// The session `id` ends (`session.end`). A /clear goes on under a new id: `id` is kept, so the work
// it started stays in view even when no look ran under it; a resume before it with no look since is
// settled first, and one that left the session where it was owes nothing. A resume puts another
// conversation in its place: the radar starts over. Any other end ends the process.
async function ends($: EngineInterface, reason: string, id: string) {
  if (reason === 'resume') return forget($, id)
  if (reason !== 'clear') return
  await arrive($, id)
  left = null
  await remember($, id)
}

// A resume leaves the conversation `from` for another: the ids, verdicts and delegated rows the
// radar holds are the old one's, so it starts over, and the next look judges every process again
// under the resumed one's id. The rows go with no toast (their work has not ended); subagent rows
// stay. A look in flight at the resume, or one made before the new id lands, takes the old one's
// work back, so the start over is owed again until the session is seen under another id.
async function forget($: EngineInterface, from: string | null) {
  left = from
  hadIds.clear()
  verdicts.clear()
  lastSeen.clear()
  await update($, sessions, () => [])
  await update($, agents, list => list.filter(a => !isDelegated(a)))
}

// The session is seen under `id`: after a resume, another id than the one it left is the resumed
// conversation's, and the start over owed is made now.
async function arrive($: EngineInterface, id: string) {
  if (left !== null && id !== left) await forget($, null)
}

// Look for delegated work and bring the rows up to date: a new process gets a running row, and a
// running row whose process has gone ends, with a toast. Unless asked (`/radar`), it looks only
// while something draws the session. A look that fails changes nothing.
// One look at a time: a /radar during one waits for it, so it reads the rows as that look leaves
// them, and looks itself only when that one stopped short with nothing drawing the session, or a
// start over is still owed after it (`left`): a resume landed during it, so it may have looked as
// the conversation left. One that looked and failed is not run again: /radar shows the rows as
// they were, as when its own look fails, and the next look tries again.
async function look($: EngineInterface, isAsked = false): Promise<void> {
  if (looking) {
    if (isAsked && (!(await looking) || left !== null)) await look($, true)
    return
  }
  looking = lookNow($, isAsked).finally(() => {
    looking = null
  })
  await looking
}

// One look: false when, not asked, it found nothing drawing the session and stopped short.
async function lookNow($: EngineInterface, isAsked: boolean): Promise<boolean> {
  try {
    if (!isAsked && !(await isWatched($))) return false
    const id = await $.session.id()
    await arrive($, id)
    const ids = [...new Set([...(await remember($, id)), ...hadIds])]
    const at = Date.now()
    const looked = await findDelegates($, ids, at)
    if (looked === null) return true
    const { found, procs } = looked
    const list = await read($, agents)
    const rows = found.map(d => rowFor(list, d))
    // The rows still running: those of the work found, and any whose process is still listed
    // though it has no verdict now (after a reload, or an environment grep could not read).
    const live = new Set([...rows, ...list.filter(a => isDelegated(a) && a.status === 'running' && stillRuns(procs, at, a)).map(a => a.id)])
    const have = new Set(list.map(a => a.id))
    const fresh: RadarAgent[] = []
    for (const [i, d] of found.entries()) {
      const id = rows[i]!
      if (have.has(id)) continue
      const cwd = await $.fs.stat(`/proc/${d.pid}/cwd`, { resolve: true }).then(
        s => s.realPath,
        () => undefined,
      )
      fresh.push({ id, description: d.label, type: 'delegated', status: 'running', startedAt: d.startedAt, tools: 0, last: 'running', pid: d.pid, cwd })
    }
    let ended: RadarAgent[] = []
    await update($, agents, list => {
      ended = list.filter(a => isDelegated(a) && a.status === 'running' && !live.has(a.id))
      const done = new Set(ended.map(a => a.id))
      const known = new Set(list.map(a => a.id))
      const updated = list.map(a => (done.has(a.id) ? { ...a, status: 'ended' as const, endedAt: lastSeen.get(a.id) ?? at, last: 'ended' } : a))
      return keep([...fresh.filter(a => !known.has(a.id)), ...updated])
    })
    for (const key of live) lastSeen.set(key, at)
    for (const a of ended) {
      const endedAt = lastSeen.get(a.id) ?? at
      lastSeen.delete(a.id)
      $.ui.toast(`■ ${a.description} ended (${elapsed({ startedAt: a.startedAt, endedAt })})`)
    }
  } catch {
    // a look that fails changes nothing; the next one tries again
  }
  return true
}

// Every piece of delegated work running now that carries one of `ids`, with the listing it was
// found in, or null when the look could not be made (ps would not run, was cut short or ran too
// long to read starts by, or grep's counts were cut short), so the caller ends nothing on a failed
// look. Either command still running at MAX_PS_MS is killed and the call rejects, which fails the
// look too. The environments are read by grep alone and never enter the mod.
async function findDelegates($: EngineInterface, ids: readonly string[], at: number): Promise<{ found: Delegate[]; procs: Proc[] } | null> {
  const asked = await $.clock.now()
  const ps = await $.process.run(PS, { timeoutMs: MAX_PS_MS })
  if (ps.exitCode !== 0 || ps.isStdoutTruncated || (await $.clock.now()) - asked > MAX_PS_MS) return null
  const procs = parsePs(ps.stdout)
  const { labels, unjudged } = triage(procs, at, verdicts)
  if (unjudged.length > 0 && ids.length > 0) {
    const counts = await $.process.run(grepArgv(unjudged), { stdin: grepPatterns(ids), timeoutMs: MAX_PS_MS })
    if (counts.isStdoutTruncated) return null
    judge(counts.stdout, unjudged, procs, at, verdicts)
  }
  return { found: ours(procs, labels, verdicts), procs }
}

export function elapsed(a: Pick<RadarAgent, 'startedAt' | 'endedAt'>, at = Date.now()) {
  const s = Math.max(0, Math.round(((a.endedAt ?? at) - a.startedAt) / 1000))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`
}

// An adopted agent's startedAt is the moment of its adoption, not its real start, so any clock on
// it is a lower bound: shown with a trailing + while it runs, and once it finishes under the
// radar's watch. One that had already finished when adopted has no clock at all.
export function duration(a: Pick<RadarAgent, 'startedAt' | 'endedAt' | 'status' | 'adopted'>, at = Date.now()) {
  if (!a.adopted) return elapsed(a, at)
  if (a.status !== 'running' && a.endedAt === undefined) return 'duration unknown'
  return `${elapsed(a, at)}+`
}

// A short label for one tool call: what a person would say the agent is doing.
export function describe(e: Record<string, unknown>): string {
  const tool = String(e.tool)
  const s = (k: string) => (typeof e[k] === 'string' ? (e[k] as string) : '')
  const file = (p: string) => p.split('/').slice(-2).join('/')
  if (tool === 'Bash') return `running ${s('description') || s('command').slice(0, 50)}`
  if (tool === 'Edit' || tool === 'Write') return `editing ${file(s('file_path'))}`
  if (tool === 'Read') return `reading ${file(s('file_path'))}`
  if (tool === 'Grep' || tool === 'Glob') return `searching ${s('pattern').slice(0, 30)}`
  if (tool.includes('playwright')) return `browser: ${tool.split('__').pop()?.replace(/^browser_/, '')}`
  if (tool.startsWith('mcp__')) return `using ${tool.split('__').slice(1).join(' ')}`
  return `using ${tool}`
}
