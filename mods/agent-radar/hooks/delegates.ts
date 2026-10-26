// Delegated work outside the session: a local addition, not from upstream (see ../NOTICE.md).
//   A process this session started carries its id in CLAUDE_CODE_SESSION_ID, and so does every
//   process that one starts, detached or not. The radar lists those that run a known kind of
//   delegated work: a Codex run, a /codex:rescue job, CE's cross-model peer, a Pro review, a
//   headless Claude. A label comes from the program a process runs, never from its command text.

export type Proc = { pid: number; ppid: number; etimes: number; args: string }

// One piece of delegated work as a look found it: the outermost process of its chain.
export type Delegate = { pid: number; label: string; startedAt: number }

// Whether a process carries one of the session's ids, judged once per process: keyed by pid,
// with the start time it had then, so a reused pid is judged again.
export type Verdicts = Map<number, { startedAt: number; isOurs: boolean }>

// `ps x` is every process this user runs; 300 columns keep a script's name and its first
// arguments and cut the several-kilobyte command lines a browser's processes carry.
export const PS = ['ps', 'x', '-o', 'pid=,ppid=,etimes=,args=', '--cols', '300'] as const

// A process younger than this at first sight is left for the next look: a quick status call
// should not flash a row and a toast.
const MIN_AGE_S = 3
// The start time is derived from `etimes`, whole seconds, against the moment the look began; a
// `ps` that starts late on a loaded host reads them later still. Two readings of one process's
// start agree to within this when neither `ps` took longer than MAX_PS_MS (a second for the
// rounding, the rest for the lateness). A pid reused within it would pass for the same process,
// and reuse needs the whole pid space to wrap first.
const SAME_START_MS = 5_000
// A `ps` slower than this reads starts too late to match a row: the look fails and changes nothing.
// Each command a look runs is killed at this too, so a `ps` or a grep hung on a process's
// environment (one in uninterruptible sleep) fails the look rather than holding /radar.
export const MAX_PS_MS = SAME_START_MS - 1_000

export function sameStart(a: number, b: number) {
  return Math.abs(a - b) <= SAME_START_MS
}

const INTERPRETERS = new Set(['bash', 'sh', 'dash', 'zsh', 'node', 'bun', 'python', 'python3'])
const CODEX_RUNS: Record<string, string> = { exec: 'Codex exec', e: 'Codex exec', review: 'Codex review' }

// The lines of `ps -o pid=,ppid=,etimes=,args=`; a line that does not parse is skipped.
export function parsePs(stdout: string): Proc[] {
  const procs: Proc[] = []
  for (const line of stdout.split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s(.*)$/.exec(line)
    if (m) procs.push({ pid: Number(m[1]), ppid: Number(m[2]), etimes: Number(m[3]), args: m[4]!.trim() })
  }
  return procs
}

const base = (word: string) => word.slice(word.lastIndexOf('/') + 1)

// What delegated work a process runs, read off the program it runs: its first word, or the
// script an interpreter runs. Null for anything else, a shell whose command merely mentions one
// of these included.
export function classify(args: string): string | null {
  const words = args.trim().split(/\s+/)
  let at = 0
  if (INTERPRETERS.has(base(words[0] ?? ''))) {
    at = 1
    while (at < words.length && words[at]!.startsWith('-')) at++
  }
  const name = base(words[at] ?? '')
  const rest = words.slice(at + 1)
  if (name === 'codex' || name === 'codex.js') return CODEX_RUNS[rest[0] ?? ''] ?? null
  if (name === 'codex-companion.mjs') return rest[0] === 'task' || rest[0] === 'task-worker' ? 'Codex rescue' : null
  if (name === 'cross-model-adversarial-review.sh') return 'CE cross-model review'
  if (name === 'oracle-review.sh') {
    const pr = numberAfter(rest, '--pr')
    return pr ? `Pro review #${pr}` : 'Pro review'
  }
  if (name === 'pro-gate-loop.sh') return /^\d+$/.test(rest[1] ?? '') ? `Pro gate #${rest[1]}` : 'Pro gate'
  if (name === 'claude' && rest.some(w => w === '-p' || w === '--print')) return 'headless Claude'
  return null
}

function numberAfter(words: string[], flag: string) {
  const i = words.indexOf(flag)
  const value = i >= 0 ? words[i + 1] : undefined
  return value !== undefined && /^\d+$/.test(value) ? value : undefined
}

// The outermost of each chain: a listed process with a listed ancestor is left out, so a Pro
// review shows once, not again for the Codex or browser driver it starts.
export function outermost(procs: Proc[], listed: Set<number>): Proc[] {
  const parent = new Map(procs.map(p => [p.pid, p.ppid]))
  return procs.filter(p => {
    if (!listed.has(p.pid)) return false
    for (let up = parent.get(p.pid), hops = 0; up !== undefined && up > 1 && hops < 64; up = parent.get(up), hops++) {
      if (listed.has(up)) return false
    }
    return true
  })
}

// One look, in steps, with the two commands it needs run by register.tsx (a module may not hand
// `$` to an imported function). `triage` labels the known kinds of work and names the processes
// still to be judged, dropping the verdict of a reused pid.
export function triage(procs: Proc[], at: number, verdicts: Verdicts) {
  const labels = new Map<number, string>()
  const unjudged: number[] = []
  for (const p of procs) {
    const label = classify(p.args)
    if (label === null) continue
    labels.set(p.pid, label)
    const known = verdicts.get(p.pid)
    if (known && sameStart(known.startedAt, at - p.etimes * 1000)) continue
    verdicts.delete(p.pid) // a reused pid: the verdict was another process's
    if (p.etimes >= MIN_AGE_S) unjudged.push(p.pid)
  }
  return { labels, unjudged }
}

// The grep that judges `pids`: for each environment it reads, a count of the session ids it holds,
// named by its file (`/proc/7/environ:1`; -H, as grep names none when it reads one file); one it
// cannot read is left out. The ids reach it on its input (`grepPatterns`), one per line, so they
// are not in its command line. The environments themselves never enter the mod.
export function grepArgv(pids: readonly number[]) {
  return ['grep', '-HcszxF', '-f', '-', '--', ...pids.map(pid => `/proc/${pid}/environ`)]
}

// grep's input: one whole environment entry per id. With no ids grep would find none in every
// environment and judge each one another session's, so the caller runs no grep then.
export function grepPatterns(ids: readonly string[]) {
  return ids.map(id => `CLAUDE_CODE_SESSION_ID=${id}\n`).join('')
}

// Records a verdict for each process grep read, from its count. One it did not read (gone, not
// readable, or grep failed) gets none and is asked about again at the next look; grep's exit code
// cannot tell those apart, so the counts are the answer.
export function judge(counts: string, pids: readonly number[], procs: Proc[], at: number, verdicts: Verdicts) {
  const read = new Map<number, boolean>()
  for (const line of counts.split('\n')) {
    const m = /^\/proc\/(\d+)\/environ:(\d+)$/.exec(line)
    if (m) read.set(Number(m[1]), Number(m[2]) > 0)
  }
  const byPid = new Map(procs.map(p => [p.pid, p]))
  for (const pid of pids) {
    const p = byPid.get(pid)
    const isOurs = read.get(pid)
    if (p && isOurs !== undefined) verdicts.set(pid, { startedAt: at - p.etimes * 1000, isOurs })
  }
}

// The delegated work running now: the outermost of each chain of the session's labelled
// processes. Verdicts for processes that are gone are dropped.
export function ours(procs: Proc[], labels: Map<number, string>, verdicts: Verdicts): Delegate[] {
  const alive = new Set(procs.map(p => p.pid))
  for (const pid of [...verdicts.keys()]) if (!alive.has(pid)) verdicts.delete(pid)
  const listed = new Set([...labels.keys()].filter(pid => verdicts.get(pid)?.isOurs === true))
  return outermost(procs, listed).map(p => ({ pid: p.pid, label: labels.get(p.pid)!, startedAt: verdicts.get(p.pid)!.startedAt }))
}

// The row a piece of delegated work belongs to: the existing row of the same process (its pid,
// and its start to within SAME_START_MS), else a new one. The module's verdicts start over when
// it reloads and the rows do not, and a start read again differs by a fraction of a second: an
// id built from it alone would end the row of a process still running and add a second one.
export function rowFor(rows: readonly { id: string; pid?: number; startedAt: number }[], d: Delegate) {
  return rows.find(a => a.pid === d.pid && sameStart(a.startedAt, d.startedAt))?.id ?? `pid:${d.pid}:${d.startedAt}`
}

// Whether a row's process still runs: its pid is listed with the same start. A row ends only when
// this is false, never for want of a verdict (a reload starts the verdicts over, and an
// environment can turn unreadable), so a process still running keeps its row.
export function stillRuns(procs: readonly Proc[], at: number, row: { pid: number; startedAt: number }) {
  return procs.some(p => p.pid === row.pid && sameStart(at - p.etimes * 1000, row.startedAt))
}
