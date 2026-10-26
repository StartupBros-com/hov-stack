// Local tests for delegated work outside the session (not from upstream; see ../NOTICE.md).
import { describe, expect, mock, test } from 'claude-code/testing'

import { MAX_PS_MS, classify, grepArgv, grepPatterns, judge, ours, outermost, parsePs, rowFor, stillRuns, triage, type Verdicts } from '../hooks/delegates'

const PANE = { component: 'Pane', requestId: 'agent-radar', props: { title: 'Agent Radar', isFocused: true, bodyColumns: 100, placement: 'dock' } }
const BAND = { component: 'AbovePrompt', props: { hasSurvey: false, isWorking: true, maxRows: 10, bodyColumns: 120 } }

// Command lines as `ps` shows them on a host running these tools.
const ORACLE = 'bash /home/user/.pro-review-daemon/oracle-review.sh'
const CODEX_JS = 'node /home/user/.local/share/pnpm/global/5/.pnpm/@openai+codex@0.160.1/node_modules/@openai/codex/bin/codex.js'
const CODEX_BIN = '/home/user/.local/share/pnpm/global/5/.pnpm/@openai+codex@0.160.1-linux-x64/node_modules/@openai/codex/vendor/x86_64-unknown-linux-musl/bin/codex'
const WORKTREE = '/home/user/dotfiles/.claude/worktrees/mods-x'

// One line of `ps -o pid=,ppid=,etimes=,args=`.
const ps = (pid: number, ppid: number, etimes: number, args: string) => `${String(pid).padStart(7)} ${String(ppid).padStart(7)} ${String(etimes).padStart(7)} ${args}`

type Process = { pid: number; ppid?: number; age: number; args: string; session?: string; cwd?: string; unreadable?: boolean }

// Stands for the engine beneath the mod and the host's processes. Each process carries the
// session id its environment holds (none: another user's sort of process); grep answers from
// those as GNU grep does, a count for each environment it reads, matching only the ids its
// patterns name (-e, or -f - from its input), and nothing for one that is `unreadable` or gone.
// The count carries the file's name only under -H or when several files are read: one file alone
// gets a bare count. `psFails` and `psCut` make the listing fail or come back cut short,
// `psLateMs` makes it come back that late, `psGate` holds the first listing on what it returns,
// `surfacesGate` holds the next surfaces read on what it returns, `grepFails` and `grepCut` make
// grep fail outright or come back cut short, and `hangs` stands for a command the host kills at
// its timeout (the call rejects). `runs` keeps each command's timeout.
// The clock holds every timer until a test moves it, so the 5 s look runs only when a test asks.
function engine(on: any) {
  const world = {
    clock: mock.clock(on),
    procs: [] as Process[],
    id: 'sid-1',
    surfaces: ['terminal'] as string[] | null,
    surfacesGate: null as (() => Promise<void>) | null,
    psFails: false,
    psCut: false,
    psLateMs: 0,
    psGate: null as (() => Promise<void>) | null,
    grepFails: false,
    grepCut: false,
    hangs: '' as '' | 'ps' | 'grep',
    psCalls: 0,
    greps: [] as { argv: string[]; stdin?: string }[],
    runs: [] as { cmd: string; timeoutMs?: number }[],
    toasts: [] as string[],
  }
  const result = (exitCode: number, stdout: string, isStdoutTruncated = false) => ({ value: { exitCode, stdout, stderr: '', isStdoutTruncated, isStderrTruncated: false } })
  on('session.start', (_$: any, e: any) => ({ sessionId: 's', cwd: e.cwd }))
  on('session.end', (_$: any, e: any) => ({ sessionId: e.sessionId }))
  on('command.register', () => ({ value: undefined }))
  on('agent.list', () => ({ value: [] }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.panes', () => ({ value: [] }))
  on('ui.toast', (_$: any, e: any) => (world.toasts.push(e.text), { value: undefined }))
  on('ui.render', ($: any, e: any) => $.ui.resolve(e).Text({ children: 'band below' }))
  on('session.messages', () => ({ value: [] }))
  on('session.id', () => ({ value: world.id }))
  on('session.surfaces', async () => {
    const gate = world.surfacesGate
    world.surfacesGate = null
    if (gate) await gate()
    if (world.surfaces === null) throw new Error('no surfaces to read')
    return { value: world.surfaces }
  })
  on('fs.stat', (_$: any, e: any) => {
    const p = world.procs.find(x => e.path === `/proc/${x.pid}/cwd`)
    if (!p?.cwd) throw new Error('ENOENT')
    return { value: { realPath: p.cwd } }
  })
  on('process.run', async (_$: any, e: any) => {
    const argv: string[] = [...e.argv]
    world.runs.push({ cmd: argv[0]!, timeoutMs: e.init?.timeoutMs })
    if (world.hangs === argv[0]) throw new Error(`${argv[0]} timed out`)
    if (argv[0] === 'ps') {
      world.psCalls++
      if (world.psGate && world.psCalls === 1) await world.psGate()
      if (world.psFails) return result(1, '')
      if (world.psLateMs > 0) await world.clock.advance(world.psLateMs) // a slow ps
      return result(0, world.procs.map(p => ps(p.pid, p.ppid ?? 1, p.age, p.args)).join('\n') + '\n', world.psCut)
    }
    if (argv[0] === 'grep') {
      world.greps.push({ argv, stdin: e.init?.stdin })
      if (world.grepFails) return result(2, '')
      const end = argv.indexOf('--')
      const opts = argv.slice(1, end)
      const files = argv.slice(end + 1)
      const flags = opts.filter((w, i) => /^-[A-Za-z]+$/.test(w) && opts[i - 1] !== '-e' && opts[i - 1] !== '-f').join('')
      const wanted = [...opts.filter((_, i) => opts[i - 1] === '-e'), ...(opts.some((w, i) => w === '-' && opts[i - 1] === '-f') ? String(e.init?.stdin ?? '').split('\n') : [])]
      const isNamed = flags.includes('H') || files.length > 1
      const counts = files.flatMap(f => {
        const p = world.procs.find(x => f === `/proc/${x.pid}/environ`)
        if (!p || p.unreadable) return []
        return [{ f, n: p.session !== undefined && wanted.includes(`CLAUDE_CODE_SESSION_ID=${p.session}`) ? 1 : 0 }]
      })
      const out = counts.map(({ f, n }) => (isNamed ? `${f}:${n}\n` : `${n}\n`))
      if (world.grepCut) return result(0, out[0] ?? '', true)
      return result(counts.length < files.length ? 2 : counts.some(c => c.n > 0) ? 0 : 1, out.join(''))
    }
    return result(127, '')
  })
  return world
}

const radar = async ($: any) => (await $.command.run({ command: 'radar', args: '' })).text as string
// The grep a look runs to judge `pids` against `ids`.
const asked = (ids: string[], pids: number[]) => ({ argv: grepArgv(pids), stdin: grepPatterns(ids) })

describe('agent-radar delegated work', () => {
  test('classify names a process by the program it runs, never by its command text', () => {
    // Codex: the npm shim, the native binary it starts, and its short spelling.
    expect(classify(`${CODEX_JS} exec - -C /work`)).toBe('Codex exec')
    expect(classify(`${CODEX_BIN} exec - -C /work`)).toBe('Codex exec')
    expect(classify('codex e "fix the parser"')).toBe('Codex exec')
    expect(classify('codex review --base main')).toBe('Codex review')
    expect(classify('/home/user/.codex/packages/app-server-daemon/releases/0.160.1/bin/codex app-server --listen unix://')).toBeNull()
    expect(classify(`${CODEX_BIN}-code-mode-host`)).toBeNull()
    // /codex:rescue's companion: a task and its worker are work; a status call is not.
    expect(classify('node /home/user/.claude/plugins/cache/openai-codex/codex/1.0.4/scripts/codex-companion.mjs task-worker --job j1')).toBe('Codex rescue')
    expect(classify('node /x/codex-companion.mjs task --background "fix it"')).toBe('Codex rescue')
    expect(classify('node /x/codex-companion.mjs status')).toBeNull()
    // CE's peer, Pro reviews and the Pro gate loop, with the PR number when the command gives one.
    expect(classify('bash /home/user/.claude/plugins/cache/every-marketplace/compound-engineering/3.30.4/skills/ce-code-review/scripts/cross-model-adversarial-review.sh claude codex 8747a81')).toBe('CE cross-model review')
    expect(classify(`${ORACLE} --pr 1660 --repo /home/user/dotfiles`)).toBe('Pro review #1660')
    expect(classify('bash -x /opt/oracle-review.sh --pr 7')).toBe('Pro review #7') // an interpreter's flags are skipped
    expect(classify(`${ORACLE} --recover marker-1`)).toBe('Pro review')
    expect(classify('bash /home/user/dotfiles/scripts/pro-gate-loop.sh /home/user/SITES/announce-bot/.claude/worktrees/w 4332 --owner-state /s')).toBe('Pro gate #4332')
    // A headless Claude; an interactive or background one is not delegated work.
    expect(classify('/home/user/.local/share/mise/installs/node/24.12.0/bin/claude -p GOAL: implement issue 449')).toBe('headless Claude')
    expect(classify('claude --model sonnet --print hello')).toBe('headless Claude')
    expect(classify('claude --setting-sources user --model sonnet --output-format json --max-turns 3 -p hello')).toBe('headless Claude')
    expect(classify('claude bg-spare --bg-spare 84cfa6bc.claim.sock')).toBeNull()
    expect(classify('claude --resume abc')).toBeNull()
    // A wrapper or a shell that only mentions one of these is not it: the wrapped child is its own
    // process and is judged on its own line.
    expect(classify('timeout 600 claude -p hello')).toBeNull()
    expect(classify('bash -c source /home/user/.claude/shell-snapshots/s.sh && codex exec hi')).toBeNull()
    expect(classify('rg -F -e codex exec')).toBeNull()
    expect(classify('/opt/google/chrome/chrome --type=renderer --lang=en-US')).toBeNull()
    expect(classify('')).toBeNull()
  })

  test('parsePs reads each line and skips one that does not parse', () => {
    const out = [ps(12, 1, 30, 'codex exec -  -C /a b'), '', 'garbage line', '   7      3      0 '].join('\n')
    expect(parsePs(out)).toEqual([
      { pid: 12, ppid: 1, etimes: 30, args: 'codex exec -  -C /a b' },
      { pid: 7, ppid: 3, etimes: 0, args: '' },
    ])
  })

  test('outermost keeps one process per chain: a listed process under a listed ancestor is left out', () => {
    const procs = parsePs([ps(10, 1, 9, 'a'), ps(11, 10, 9, 'b'), ps(12, 11, 9, 'c'), ps(20, 1, 9, 'd'), ps(30, 99, 9, 'e')].join('\n'))
    // 12 sits under 10 by way of the unlisted 11; 20 and 30 have no listed ancestor (99 is not running).
    expect(outermost(procs, new Set([10, 12, 20, 30])).map(p => p.pid)).toEqual([10, 20, 30])
    expect(outermost(procs, new Set([12])).map(p => p.pid)).toEqual([12])
  })

  test('grep names each environment it counts in, and takes the session ids on its input, not its command line', () => {
    expect(grepArgv([7, 9])).toEqual(['grep', '-HcszxF', '-f', '-', '--', '/proc/7/environ', '/proc/9/environ'])
    expect(grepArgv([7])).toEqual(['grep', '-HcszxF', '-f', '-', '--', '/proc/7/environ'])
    expect(grepPatterns(['sid-1', 'sid-2'])).toBe('CLAUDE_CODE_SESSION_ID=sid-1\nCLAUDE_CODE_SESSION_ID=sid-2\n')
  })

  test('triage, judge and ours: each process judged once, a young one later, a reused pid again, a gone one forgotten', () => {
    const at = 10_000_000
    const verdicts: Verdicts = new Map()
    let procs = parsePs([ps(7, 1, 100, `${ORACLE} --pr 3`), ps(8, 1, 100, 'codex exec x'), ps(9, 1, 1, 'codex exec y'), ps(10, 1, 100, 'vim')].join('\n'))
    let t = triage(procs, at, verdicts)
    expect([...t.labels]).toEqual([[7, 'Pro review #3'], [8, 'Codex exec'], [9, 'Codex exec']])
    expect(t.unjudged).toEqual([7, 8]) // 9 is younger than 3 s; vim is no delegated work
    judge('/proc/7/environ:1\n/proc/8/environ:0\n', t.unjudged, procs, at, verdicts)
    expect(ours(procs, t.labels, verdicts)).toEqual([{ pid: 7, label: 'Pro review #3', startedAt: at - 100_000 }])

    // A second look a second later judges only the process that has come of age.
    t = triage(procs.map(p => ({ ...p, etimes: p.etimes + 1 })), at + 1_000, verdicts)
    expect(t.unjudged).toEqual([])
    procs = procs.map(p => ({ ...p, etimes: p.pid === 9 ? 3 : p.etimes + 2 }))
    expect(triage(procs, at + 2_000, verdicts).unjudged).toEqual([9])
    judge('', [9], procs, at + 2_000, verdicts) // grep read nothing: no verdict, asked again
    expect(verdicts.has(9)).toBe(false)
    judge('/proc/9/environ:0\n', [9], procs, at + 2_000, verdicts)
    expect(verdicts.get(9)).toEqual({ startedAt: at - 1_000, isOurs: false })

    // Pid 7 now runs a new process: its verdict was another process's.
    procs = parsePs([ps(7, 1, 5, 'codex exec z'), ps(8, 1, 105, 'codex exec x')].join('\n'))
    t = triage(procs, at + 5_000, verdicts)
    expect(t.unjudged).toEqual([7])
    expect(verdicts.has(7)).toBe(false)
    judge('/proc/7/environ:0\n', t.unjudged, procs, at + 5_000, verdicts)
    expect(ours(procs, t.labels, verdicts)).toEqual([])
    expect([...verdicts.keys()].sort()).toEqual([7, 8]) // 9 is gone and forgotten
  })

  test('rowFor keeps one row per process: the same pid with a start read again matches, a new start does not', () => {
    const rows = [{ id: 'pid:7:100000', pid: 7, startedAt: 100_000 }, { id: 'a1', startedAt: 100_000 }]
    expect(rowFor(rows, { pid: 7, label: 'Codex exec', startedAt: 100_900 })).toBe('pid:7:100000')
    expect(rowFor(rows, { pid: 7, label: 'Codex exec', startedAt: 104_500 })).toBe('pid:7:100000') // read by a late ps
    expect(rowFor(rows, { pid: 7, label: 'Codex exec', startedAt: 160_000 })).toBe('pid:7:160000') // a reused pid
    expect(rowFor(rows, { pid: 8, label: 'Codex exec', startedAt: 100_000 })).toBe('pid:8:100000')
  })

  test('stillRuns: a row runs while its pid is listed with the same start', () => {
    const at = 400_000
    const procs = parsePs([ps(7, 1, 300, 'codex exec x'), ps(8, 1, 10, 'codex exec y')].join('\n'))
    expect(stillRuns(procs, at, { pid: 7, startedAt: 100_000 })).toBe(true)
    expect(stillRuns(procs, at, { pid: 7, startedAt: 104_500 })).toBe(true) // read by a late ps
    expect(stillRuns(procs, at, { pid: 8, startedAt: 100_000 })).toBe(false) // a reused pid
    expect(stillRuns(procs, at, { pid: 9, startedAt: 100_000 })).toBe(false) // gone
  })

  test('/radar shows the delegated work this session started, by program and directory, and nothing of its command text', async ($, on) => {
    const world = engine(on)
    world.procs = [
      { pid: 100, age: 300, args: `${ORACLE} --pr 1660 --repo /home/user/dotfiles --prompt SECRET-PROMPT-TEXT`, session: 'sid-1', cwd: WORKTREE },
      { pid: 101, ppid: 100, age: 290, args: `${CODEX_JS} exec - -C /home/user/dotfiles`, session: 'sid-1' },
      { pid: 102, ppid: 101, age: 290, args: `${CODEX_BIN} exec - -C /home/user/dotfiles`, session: 'sid-1' },
      { pid: 200, age: 300, args: `${ORACLE} --pr 999`, session: 'sid-other' },
      { pid: 300, age: 300, args: 'bash -c echo codex exec', session: 'sid-1' },
      { pid: 400, age: 1, args: 'claude -p hello', session: 'sid-1' },
    ]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)

    expect(await radar($)).toBe('1 running, 0 finished')
    // Only the labelled processes of age are judged, in one grep; no shell and no young process.
    expect(world.greps).toEqual([asked(['sid-1'], [100, 101, 102, 200])])

    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.find({ type: 'Text', text: /1 running · 0 finished/ })).toBeDefined()
    expect(await ui.find({ type: 'Button', text: /^● Pro review #1660 · 5m 0[01]s · mods-x$/ })).toBeDefined()
    expect(await ui.find({ text: /999|Codex exec|SECRET/ })).toBeUndefined()
    expect(JSON.stringify(await ui.drawn())).not.toContain('SECRET')
    await ui.press({ key: (await ui.find({ type: 'Button', text: /Pro review #1660/ }))!.key! })
    expect(await ui.find({ type: 'Text', text: /delegated · 5m 0[01]s/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: `pid 100 in ${WORKTREE}` })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Running outside this session/ })).toBeDefined()
    await ui.unmount()

    const band = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...BAND } as any)
    expect(await band.find({ type: 'Text', text: / ● Pro review #1660/ })).toBeDefined()
    expect(await band.find({ type: 'Text', text: /^ {2}5m 0[01]s · mods-x$/ })).toBeDefined() // where it runs, not a tool count
    expect(await band.find({ text: /tools|SECRET/ })).toBeUndefined()
    await band.unmount()
  })

  test('delegated work whose process has gone ends, with one toast; a failed or cut-short look ends nothing', async ($, on) => {
    const world = engine(on)
    world.procs = [{ pid: 110, age: 300, args: `${ORACLE} --pr 1660`, session: 'sid-1', cwd: WORKTREE }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('1 running, 0 finished')

    world.psFails = true
    expect(await radar($)).toBe('1 running, 0 finished')
    world.psFails = false
    world.psCut = true
    world.procs = []
    expect(await radar($)).toBe('1 running, 0 finished')
    expect(world.toasts).toEqual([])

    world.psCut = false
    expect(await radar($)).toBe('0 running, 1 finished')
    expect(world.toasts).toEqual(['■ Pro review #1660 ended (5m 00s)'])
    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.find({ type: 'Button', text: /^■ Pro review #1660 · 5m 00s · mods-x · ended$/ })).toBeDefined()
    await ui.unmount()

    expect(await radar($)).toBe('0 running, 1 finished')
    expect(world.toasts).toHaveLength(1)
    expect(world.greps).toHaveLength(1) // judged once, at the first look
  })

  test('a reused pid is judged again, and a process too young waits for the next look', async ($, on) => {
    const world = engine(on)
    world.procs = [{ pid: 120, age: 300, args: `${ORACLE} --pr 7`, session: 'sid-1' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('1 running, 0 finished')

    // Pid 120 is a new, young process now: the review it was has ended, and the new one waits.
    world.procs = [{ pid: 120, age: 1, args: 'claude -p summarise', session: 'sid-1' }]
    expect(await radar($)).toBe('0 running, 1 finished')
    expect(world.toasts).toEqual(['■ Pro review #7 ended (5m 00s)'])
    expect(world.greps).toHaveLength(1)

    world.procs = [{ pid: 120, age: 4, args: 'claude -p summarise', session: 'sid-1' }]
    expect(await radar($)).toBe('1 running, 1 finished')
    expect(world.greps).toEqual([asked(['sid-1'], [120]), asked(['sid-1'], [120])])
    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.find({ type: 'Button', text: /^● headless Claude · [45]s · pid 120$/ })).toBeDefined() // no directory read: pid instead
    await ui.unmount()
  })

  test('work started before a /clear stays in view: a look asks after every id the process has had', async ($, on) => {
    const world = engine(on)
    world.procs = [{ pid: 130, age: 60, args: 'codex exec one', session: 'sid-1' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('1 running, 0 finished')

    world.id = 'sid-2'
    world.procs.push({ pid: 131, age: 30, args: 'codex review --base main', session: 'sid-1' }, { pid: 132, age: 5, args: 'codex exec two', session: 'sid-2' })
    expect(await radar($)).toBe('3 running, 0 finished')
    expect(world.greps[1]).toEqual(asked(['sid-1', 'sid-2'], [131, 132]))
  })

  test('a /clear keeps the id that ends, even when no look ran under it', async ($, on) => {
    const world = engine(on)
    world.surfaces = [] // nothing draws, so the timer never looks
    world.procs = [{ pid: 133, age: 60, args: 'codex exec one', session: 'sid-1' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    await world.clock.advance(5_000)
    expect(world.psCalls).toBe(0)

    await $.session.end({ reason: 'clear', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    world.id = 'sid-2'
    expect(await radar($)).toBe('1 running, 0 finished')
    expect(world.greps).toEqual([asked(['sid-1', 'sid-2'], [133])])
  })

  test("the ids outlive the host's list: a /clear that started its values over loses no work", async ($, on) => {
    const world = engine(on)
    on('state.set', (_$: any, e: any, next: any) => next(e.key === 'sessions' ? { ...e, value: [] } : e)) // the host keeps no ids
    world.procs = [{ pid: 134, age: 60, args: 'codex exec one', session: 'sid-1' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('1 running, 0 finished')

    await $.session.end({ reason: 'clear', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    world.id = 'sid-2'
    world.procs.push({ pid: 135, age: 30, args: 'codex exec two', session: 'sid-1' })
    expect(await radar($)).toBe('2 running, 0 finished')
    expect(world.greps[1]).toEqual(asked(['sid-2', 'sid-1'], [135]))
  })

  // A resume puts another conversation in the session's place, in the same process: no
  // session.start fires, and the session goes on under the resumed conversation's id.
  test('a resume drops the conversation it left: its work leaves the radar with no toast, and its id is no longer asked after', async ($, on) => {
    const world = engine(on)
    world.procs = [{ pid: 250, age: 300, args: `${ORACLE} --pr 1`, session: 'sid-1' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('1 running, 0 finished')

    await $.session.end({ reason: 'resume', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    world.id = 'sid-2'
    world.procs.push({ pid: 251, age: 30, args: 'codex exec one', session: 'sid-1' })
    expect(await radar($)).toBe('0 running, 0 finished')
    expect(world.toasts).toEqual([])
    expect(world.greps[1]).toEqual(asked(['sid-2'], [250, 251]))
  })

  test('a resume judges again what it saw before: work of the resumed conversation, first seen under another, is listed', async ($, on) => {
    const world = engine(on)
    world.procs = [{ pid: 255, age: 300, args: 'codex exec one', session: 'sid-2' }] // started by sid-2 in an earlier process
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('0 running, 0 finished') // another conversation's, while sid-1 is current

    await $.session.end({ reason: 'resume', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    world.id = 'sid-2'
    expect(await radar($)).toBe('1 running, 0 finished')
    expect(world.greps).toEqual([asked(['sid-1'], [255]), asked(['sid-2'], [255])])
  })

  test('a resume during a look in flight: that look does not bring back the conversation left', async ($, on) => {
    const world = engine(on)
    world.procs = [
      { pid: 260, age: 60, args: `${ORACLE} --pr 1`, session: 'sid-1' },
      { pid: 261, age: 60, args: 'codex exec one', session: 'sid-2' },
    ]
    let reached = () => {}
    let open = () => {}
    const isReached = new Promise<void>(resolve => (reached = resolve))
    world.psGate = () => (reached(), new Promise<void>(resolve => (open = resolve)))
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    const first = radar($) // its look, under sid-1, held on its ps
    await isReached
    await $.session.end({ reason: 'resume', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    world.id = 'sid-2'
    open()
    await first // that look ends as sid-1's, and takes 260 back

    expect(await radar($)).toBe('1 running, 0 finished')
    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.find({ type: 'Button', text: /^● Codex exec · / })).toBeDefined()
    expect(await ui.find({ type: 'Button', text: /Pro review/ })).toBeUndefined()
    await ui.unmount()
    expect(world.greps).toEqual([asked(['sid-1'], [260, 261]), asked(['sid-2'], [260, 261])])
    expect(world.toasts).toEqual([])
  })

  test('a resume whose new id has not landed yet: a look then takes the old work back, and the next look under the new id drops it', async ($, on) => {
    const world = engine(on)
    world.procs = [{ pid: 265, age: 60, args: 'codex exec one', session: 'sid-1' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('1 running, 0 finished')

    await $.session.end({ reason: 'resume', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    expect(await radar($)).toBe('1 running, 0 finished') // the session still reads sid-1
    world.id = 'sid-2'
    expect(await radar($)).toBe('0 running, 0 finished')
    expect(world.toasts).toEqual([])
    expect(world.greps).toEqual([asked(['sid-1'], [265]), asked(['sid-1'], [265]), asked(['sid-2'], [265])])
  })

  test("a /clear soon after a resume, before any look, keeps the resumed conversation's id", async ($, on) => {
    const world = engine(on)
    world.surfaces = [] // nothing draws, so the timer never looks
    world.procs = [{ pid: 270, age: 60, args: 'codex exec one', session: 'sid-2' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    await $.session.end({ reason: 'resume', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    world.id = 'sid-2'
    await $.session.end({ reason: 'clear', sessionId: 'sid-2', resume: { id: 'sid-2' } } as any)
    world.id = 'sid-3'
    expect(await radar($)).toBe('1 running, 0 finished')
    expect(world.greps).toEqual([asked(['sid-2', 'sid-3'], [270])])
  })

  test('a resume that leaves the session where it was, then a /clear: the id it had is kept', async ($, on) => {
    const world = engine(on)
    world.surfaces = [] // nothing draws, so the timer never looks
    world.procs = [{ pid: 275, age: 60, args: 'codex exec one', session: 'sid-1' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    await $.session.end({ reason: 'resume', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any) // it goes on as sid-1
    await $.session.end({ reason: 'clear', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    world.id = 'sid-2'
    expect(await radar($)).toBe('1 running, 0 finished')
    expect(world.greps).toEqual([asked(['sid-1', 'sid-2'], [275])])
  })

  test('a /clear after a resume whose new id had not landed at the last look keeps neither the id left nor its work', async ($, on) => {
    const world = engine(on)
    world.surfaces = [] // nothing draws, so the timer never looks
    world.procs = [
      { pid: 285, age: 60, args: `${ORACLE} --pr 1`, session: 'sid-1' },
      { pid: 286, age: 60, args: 'codex exec one', session: 'sid-2' },
    ]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    await $.session.end({ reason: 'resume', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    expect(await radar($)).toBe('1 running, 0 finished') // the session still reads sid-1: its work is taken back
    world.id = 'sid-2'
    await $.session.end({ reason: 'clear', sessionId: 'sid-2', resume: { id: 'sid-2' } } as any)
    world.id = 'sid-3'

    expect(await radar($)).toBe('1 running, 0 finished')
    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.find({ type: 'Button', text: /^● Codex exec · / })).toBeDefined()
    expect(await ui.find({ type: 'Button', text: /Pro review/ })).toBeUndefined()
    await ui.unmount()
    expect(world.greps).toEqual([asked(['sid-1'], [285, 286]), asked(['sid-2', 'sid-3'], [285, 286])])
    expect(world.toasts).toEqual([])
  })

  test('a /radar that joins a look in flight at a resume looks again under the resumed id', async ($, on) => {
    const world = engine(on)
    world.procs = [
      { pid: 295, age: 60, args: `${ORACLE} --pr 1`, session: 'sid-1' },
      { pid: 296, age: 60, args: 'codex exec one', session: 'sid-2' },
    ]
    let reached = () => {}
    let open = () => {}
    const isReached = new Promise<void>(resolve => (reached = resolve))
    world.psGate = () => (reached(), new Promise<void>(resolve => (open = resolve)))
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    await world.clock.advance(5_000) // the timer's look, under sid-1, held on its ps
    await isReached
    await $.session.end({ reason: 'resume', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    world.id = 'sid-2'
    const answer = radar($) // joins the timer's look
    await world.clock.settle()
    open()

    expect(await answer).toBe('1 running, 0 finished')
    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.find({ type: 'Button', text: /^● Codex exec · / })).toBeDefined()
    expect(await ui.find({ type: 'Button', text: /Pro review/ })).toBeUndefined()
    await ui.unmount()
    expect(world.greps).toEqual([asked(['sid-1'], [295, 296]), asked(['sid-2'], [295, 296])])
    expect(world.toasts).toEqual([])
  })

  test('a resume drops only the delegated rows: a subagent row stays', async ($, on) => {
    const world = engine(on)
    on('agent.spawn', () => ({ model: 'sonnet', agentId: 'a1' }))
    world.procs = [{ pid: 290, age: 60, args: 'codex exec one', session: 'sid-1' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    await $.agent.spawn({ prompt: 'run it', description: 'sweep runner' } as any)
    expect(await radar($)).toBe('2 running, 0 finished')

    await $.session.end({ reason: 'resume', sessionId: 'sid-1', resume: { id: 'sid-1' } } as any)
    world.id = 'sid-2'
    expect(await radar($)).toBe('1 running, 0 finished')
    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.find({ type: 'Button', text: /^● sweep runner · / })).toBeDefined()
    expect(await ui.find({ type: 'Button', text: /Codex exec/ })).toBeUndefined()
    await ui.unmount()
  })

  test('a process grep could not read, or a grep that failed, gets no verdict and is asked about again', async ($, on) => {
    const world = engine(on)
    world.procs = [
      { pid: 160, age: 60, args: 'codex exec one', session: 'sid-1' },
      { pid: 161, age: 60, args: 'codex exec two', session: 'sid-other' },
      { pid: 162, age: 60, args: 'codex exec three', session: 'sid-1', unreadable: true },
    ]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('1 running, 0 finished')
    expect(await radar($)).toBe('1 running, 0 finished')
    // 161 was read and is another session's, judged for good; 162 could not be read.
    expect(world.greps).toEqual([asked(['sid-1'], [160, 161, 162]), asked(['sid-1'], [162])])

    world.grepFails = true
    world.procs.push({ pid: 163, age: 10, args: 'codex review --base main', session: 'sid-1' })
    expect(await radar($)).toBe('1 running, 0 finished')
    world.grepFails = false
    expect(await radar($)).toBe('2 running, 0 finished')
    expect(world.greps.slice(2)).toEqual([asked(['sid-1'], [162, 163]), asked(['sid-1'], [162, 163])])
    expect(world.toasts).toEqual([])
  })

  test('a ps too slow to read starts by changes nothing', async ($, on) => {
    const world = engine(on)
    world.procs = [{ pid: 170, age: 300, args: `${ORACLE} --pr 1660`, session: 'sid-1' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    world.psLateMs = 3_500 // slow, but not too slow
    expect(await radar($)).toBe('1 running, 0 finished')

    world.procs = []
    world.psLateMs = 4_500
    expect(await radar($)).toBe('1 running, 0 finished')
    expect(world.toasts).toEqual([])
    world.psLateMs = 0
    expect(await radar($)).toBe('0 running, 1 finished')
    expect(world.toasts).toEqual(['■ Pro review #1660 ended (5m 00s)'])
  })

  test('a running process keeps its one row when its start is read again a fraction of a second off, as after a reload', async ($, on) => {
    const world = engine(on)
    world.procs = [{ pid: 150, age: 300, args: `${ORACLE} --pr 1660`, session: 'sid-1', cwd: WORKTREE }]
    // A reload starts the module's verdicts over and keeps the host's rows, so the next look reads
    // the process's start again, a fraction of a second off the row's. Stand for that by storing
    // the row with a start 700 ms off the one the module judged.
    let isShifted = false
    on('state.set', (_$: any, e: any, next: any) => {
      if (e.key !== 'agents' || isShifted) return next(e)
      const value = e.value.map((a: any) => (a.pid === 150 ? ((isShifted = true), { ...a, id: `pid:150:${a.startedAt + 700}`, startedAt: a.startedAt + 700 }) : a))
      return next({ ...e, value })
    })
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('1 running, 0 finished')
    expect(isShifted).toBe(true)

    expect(await radar($)).toBe('1 running, 0 finished')
    expect(world.toasts).toEqual([])
    const ui = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...PANE } as any)
    expect(await ui.findAll({ type: 'Button', text: /Pro review #1660/ })).toHaveLength(1)
    await ui.unmount()
  })

  test('the timer looks every 5 s while something draws the session, and not while nothing does', async ($, on) => {
    const world = engine(on)
    const clock = world.clock
    world.procs = [{ pid: 140, age: 300, args: 'codex exec one', session: 'sid-1' }]
    world.surfaces = []
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)

    await clock.advance(5_000)
    expect(world.psCalls).toBe(0)

    world.surfaces = ['terminal']
    await clock.advance(5_000)
    expect(world.psCalls).toBe(1)
    const band = await $.ui.mount({ plugin: 'agent-radar', surface: 'terminal', ...BAND } as any)
    expect(await band.find({ type: 'Text', text: / ● Codex exec/ })).toBeDefined()
    await band.unmount()

    // A surfaces read that fails counts as watched.
    world.surfaces = null
    world.procs = []
    await clock.advance(5_000)
    expect(world.psCalls).toBe(2)
    expect(world.toasts).toEqual(['■ Codex exec ended (5m 00s)'])
  })

  test('a lone new process is judged and shown: grep names the one environment it reads', async ($, on) => {
    const world = engine(on)
    world.procs = [{ pid: 190, age: 60, args: 'codex exec one', session: 'sid-1' }]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('1 running, 0 finished')
    expect(await radar($)).toBe('1 running, 0 finished')
    expect(world.greps).toHaveLength(1) // judged for good at the first look
  })

  test('a running row stays running while its process runs, its environment unreadable, as after a reload', async ($, on) => {
    const world = engine(on)
    world.procs = [
      { pid: 180, age: 300, args: `${ORACLE} --pr 1660`, session: 'sid-1' },
      { pid: 181, age: 300, args: 'codex exec two', session: 'sid-1', unreadable: true },
    ]
    // A reload starts the module's verdicts over and keeps the host's rows. Stand for that with a
    // row for 181 the module never judged, stored beside 180's the first time the rows are.
    let isSeeded = false
    on('state.set', (_$: any, e: any, next: any) => {
      const row = e.key === 'agents' && !isSeeded ? e.value.find((a: any) => a.pid === 180) : undefined
      if (!row) return next(e)
      isSeeded = true
      return next({ ...e, value: [...e.value, { ...row, id: `pid:181:${row.startedAt}`, pid: 181, description: 'Codex exec' }] })
    })
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('2 running, 0 finished')
    expect(isSeeded).toBe(true)

    expect(await radar($)).toBe('2 running, 0 finished')
    expect(await radar($)).toBe('2 running, 0 finished')
    expect(world.toasts).toEqual([])

    // It ends when its process does, with its one toast.
    world.procs = world.procs.filter(p => p.pid !== 181)
    expect(await radar($)).toBe('1 running, 1 finished')
    expect(world.toasts).toEqual(['■ Codex exec ended (5m 00s)'])
  })

  test('every ps and grep is bounded, and one the host kills at its timeout changes nothing', async ($, on) => {
    const world = engine(on)
    world.procs = [
      { pid: 210, age: 60, args: 'codex exec one', session: 'sid-1' },
      { pid: 211, age: 60, args: 'codex exec two', session: 'sid-1' },
    ]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    expect(await radar($)).toBe('2 running, 0 finished')
    expect(world.runs).toEqual([{ cmd: 'ps', timeoutMs: MAX_PS_MS }, { cmd: 'grep', timeoutMs: MAX_PS_MS }])

    world.procs = [{ pid: 212, age: 60, args: 'codex exec three', session: 'sid-1' }]
    world.hangs = 'ps'
    expect(await radar($)).toBe('2 running, 0 finished')
    world.hangs = 'grep'
    expect(await radar($)).toBe('2 running, 0 finished')
    expect(world.toasts).toEqual([])
    world.hangs = ''
    expect(await radar($)).toBe('1 running, 2 finished')
    expect(world.toasts).toHaveLength(2)
    expect(world.runs.filter(r => r.timeoutMs !== MAX_PS_MS)).toEqual([])
  })

  test('a grep cut short judges nothing', async ($, on) => {
    const world = engine(on)
    world.procs = [
      { pid: 220, age: 60, args: 'codex exec one', session: 'sid-1' },
      { pid: 221, age: 60, args: 'codex exec two', session: 'sid-1' },
    ]
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    world.grepCut = true
    expect(await radar($)).toBe('0 running, 0 finished')
    world.grepCut = false
    expect(await radar($)).toBe('2 running, 0 finished')
  })

  test('one look at a time: a /radar during a slow look waits for it and shows what it found, never a stale count', async ($, on) => {
    const world = engine(on)
    world.procs = [
      { pid: 230, age: 60, args: 'codex exec one', session: 'sid-1' },
      { pid: 231, age: 60, args: 'codex exec two', session: 'sid-1' },
    ]
    let reached = () => {}
    let open = () => {}
    const isReached = new Promise<void>(resolve => (reached = resolve))
    world.psGate = () => (reached(), new Promise<void>(resolve => (open = resolve)))
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    const first = radar($)
    await isReached
    let isAnswered = false
    const second = radar($).then(text => ((isAnswered = true), text))
    await world.clock.settle()
    const wasAnswered = isAnswered // while the first look still waits on its ps
    open()
    expect(await Promise.all([first, second])).toEqual(['2 running, 0 finished', '2 running, 0 finished'])
    expect(wasAnswered).toBe(false)
    expect(world.psCalls).toBe(1) // the look it waited on had looked: no second one
    expect(world.greps).toHaveLength(1)
  })

  test('a /radar during a timer look that stopped short, nothing drawing the session, looks itself', async ($, on) => {
    const world = engine(on)
    world.procs = [{ pid: 240, age: 60, args: 'codex exec one', session: 'sid-1' }]
    world.surfaces = [] // nothing draws, so the timer's look stops short
    let reached = () => {}
    let open = () => {}
    const isReached = new Promise<void>(resolve => (reached = resolve))
    world.surfacesGate = () => (reached(), new Promise<void>(resolve => (open = resolve)))
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    await world.clock.advance(5_000) // the timer's look, held on its surfaces read
    await isReached
    let isAnswered = false
    const answer = radar($).then(text => ((isAnswered = true), text))
    await world.clock.settle()
    const wasAnswered = isAnswered // while the timer's look still waits on its surfaces read
    open()
    expect(await answer).toBe('1 running, 0 finished')
    expect(wasAnswered).toBe(false)
    expect(world.psCalls).toBe(1) // the timer's look made none; /radar made its own
    expect(world.greps).toEqual([asked(['sid-1'], [240])])
  })
})
