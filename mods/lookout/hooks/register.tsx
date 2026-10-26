// lookout: a second pair of eyes while Claude works. Every few main-thread model steps, one
// tool-less fork of the session's own transcript (served from the main thread's prompt cache) is
// asked whether there is something the person should know and might miss; the answer shows above
// the prompt until it is dismissed or two prompts have gone by. No model call while nothing draws
// the session, so a background job nobody is attached to costs nothing.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

const DEFAULT_EVERY = 6
const MAX_EVERY = 1000
const CLEAR_AFTER_PROMPTS = 2
const MAX_FLAG = 280
const MAX_FLAGS_KEPT = 20
const FLAGS_IN_QUESTION = 5
const OFF_KEY = 'off'
const NONE = /^none\.?$/i

// Held by the host, so a flag on screen survives a hot reload of this file.
const card = atom({ plugin: 'lookout', key: 'card' } as const, null as string | null)

const USAGE = [
  '/lookout        on or off, the last check, what the checks cost, the flags so far',
  '/lookout now    check at once',
  '/lookout off    stop checking, in this session and later ones',
  '/lookout on     start again',
].join('\n')

// What one load of the module keeps between hooks; a hot reload starts it over.
type Watch = Conversation & {
  every: number
  isOff: boolean
  // The conversation whose check is out, or null. Not reset with the rest at a /clear or a resume:
  // the next conversation is free to check because the number has moved on, and a check from the
  // ended one that settles later clears only its own mark, never a newer check's.
  checking: number | null
  // Moves on each /lookout off, so a check begun before it neither forks nor shows its flag,
  // even when lookout is back on by the time the check gets that far.
  generation: number
  // Moves when a conversation ends, so a check begun in it sends, counts and shows nothing after.
  conversation: number
  // Why the on/off switch in `$.store` may not match this session, after a read or save of it
  // failed; null once a save goes through.
  unsaved: string | null
}

// What lookout has seen of one conversation; the next one in the process starts from `fresh()`.
type Conversation = {
  mainSteps: number
  promptsSinceFlag: number
  flags: string[]
  last: string
  spent: { checks: number; input: number; cacheRead: number; cacheWrite: number; output: number }
}

function fresh(): Conversation {
  return {
    mainSteps: 0,
    promptsSinceFlag: 0,
    flags: [],
    last: 'none yet',
    spent: { checks: 0, input: 0, cacheRead: 0, cacheWrite: 0, output: 0 },
  }
}

export const register: Register = (on, options) => {
  const w: Watch = {
    every: everyOf(options.every),
    isOff: false,
    checking: null,
    generation: 0,
    conversation: 0,
    unsaved: null,
    ...fresh(),
  }

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    // A switch that cannot be read counts as off: each fork reads the whole transcript, so lookout
    // sends none the person may have turned off.
    w.isOff = await $.store.get(OFF_KEY).then(
      value => value === true,
      error => {
        w.unsaved = `could not be read (${reason(error)}), so lookout started off`
        return true
      },
    )
    await $.command
      .register({ name: 'lookout', description: 'Lookout status; /lookout now checks at once, /lookout off or on' })
      .catch(() => {}) // a name Claude Code already has is refused: start anyway
    return started
  })

  // A /clear or a resume goes on in this process under another conversation, and no session.start
  // fires for it: what lookout saw of this one ends here, a check still out included. Only the
  // on/off switch carries over. Should clearing the flag on screen fail, the end still goes through.
  on('session.end', async ($, e, next) => {
    Object.assign(w, fresh())
    w.conversation++
    await update($, card, () => null).catch(() => {})
    return next(e)
  })

  // Count the main thread's model steps; the fork reads the main thread's transcript, so a
  // subagent's steps would only make it ask about the same conversation more often.
  on('turn.step', async function* ($, e, next) {
    const result = yield* next(e)
    if (!e.agentId && w.every > 0 && !w.isOff && ++w.mainSteps % w.every === 0) void check($, w)
    return result
  })

  // A flag stays for one more prompt and clears on the second. Should clearing it fail, the
  // prompt still goes through untouched.
  on('prompt.submit', async ($, e, next) => {
    if ((await read($, card)) !== null && ++w.promptsSinceFlag >= CLEAR_AFTER_PROMPTS) {
      await update($, card, () => null)
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'lookout' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    if (arg === '') return { text: status(w) }
    if (arg === 'now') {
      if (w.isOff) return { text: 'lookout is off, so it sent no check. /lookout on turns it back on.' }
      if (w.checking === w.conversation) return { text: 'lookout already has a check out; its flag, if there is one, shows above the prompt.' }
      void check($, w)
      return { text: 'lookout is checking now; a flag, if there is one, shows above the prompt.' }
    }
    // Each switch holds in this session whatever the store does; only the reply about later
    // sessions depends on the save.
    if (arg === 'off') {
      w.isOff = true
      w.generation++
      const unsaved = await save(w, $.store.set(OFF_KEY, true), 'a later session may start with it on')
      await update($, card, () => null)
      return {
        text: unsaved
          ? `lookout is off in this session, but the setting ${unsaved}. /lookout on turns it back on.`
          : 'lookout is off, in this session and later ones. /lookout on turns it back on.',
      }
    }
    if (arg === 'on') {
      w.isOff = false
      const unsaved = await save(w, $.store.delete(OFF_KEY), 'a later session may still start with it off')
      return {
        text: unsaved
          ? `lookout is on in this session: ${cadence(w)}. The setting ${unsaved}.`
          : `lookout is on: ${cadence(w)}.`,
      }
    }
    return { text: USAGE }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    const flag = await read($, card)
    if (e.props.hasSurvey || flag === null) return below

    const { Box, Text, Button } = $.ui.resolve(e)
    const rows = [
      <Box key="lookout" flexDirection="row" columnGap={1} paddingX={1}>
        <Text key="mark" color="magenta" bold>
          ✦ lookout
        </Text>
        <Text key="flag" wrap="wrap">
          {flag}
        </Text>
        <Button
          key="dismiss"
          label="ok"
          hotkey="o"
          plain
          role="dismiss"
          onPress={() => void update($, card, () => null)}
        />
      </Box>,
    ]
    if (below) rows.push(below)
    return <Box flexDirection="column">{rows}</Box>
  })
}

// One check at a time in a conversation: a step that comes due while a fork is still out is
// skipped, not queued. A check whose conversation ended while it waited leaves the next one's
// record untouched and does not hold back its checks.
async function check($: EngineInterface, w: Watch) {
  if (w.checking === w.conversation) return
  const generation = w.generation
  const conversation = w.conversation
  w.checking = conversation
  try {
    if (!(await isWatched($)) || conversation !== w.conversation) return
    if (generation !== w.generation) {
      w.last = 'no check sent: lookout was turned off as it started'
      return
    }
    const reply = await $.model.fork({ prompt: question(w.flags.slice(-FLAGS_IN_QUESTION)) })
    if (conversation !== w.conversation) return
    if ('usage' in reply) {
      w.spent.checks++
      w.spent.input += reply.usage.input_tokens ?? 0
      w.spent.cacheRead += reply.usage.cache_read_input_tokens ?? 0
      w.spent.cacheWrite += reply.usage.cache_creation_input_tokens ?? 0
      w.spent.output += reply.usage.output_tokens ?? 0
    }
    if (!reply.isAnswered) {
      w.last =
        reply.reason === 'api-error' ? `api-error ${reply.status ?? 'no response'} (${reply.error})` : reply.reason
      return
    }
    const flag = parse(reply.text)
    if (flag === undefined) w.last = 'a reply not in the expected shape'
    else if (flag === null) w.last = 'nothing to flag'
    else if (w.flags.some(seen => sameFlag(seen, flag))) w.last = 'a flag already shown'
    else if (generation !== w.generation) w.last = 'a flag not shown: lookout was turned off while the check was out'
    else {
      w.flags = [...w.flags, flag].slice(-MAX_FLAGS_KEPT)
      w.last = 'flagged'
      w.promptsSinceFlag = 0
      // `update` runs this again when another write beat it, as a /clear or an off clearing the
      // card does; by then the flag is no longer this check's to show.
      await update($, card, shown => (conversation === w.conversation && generation === w.generation ? flag : shown))
    }
  } catch {
    if (conversation === w.conversation) w.last = 'the check could not be sent'
  } finally {
    if (w.checking === conversation) w.checking = null
  }
}

// Waits for a write of the on/off switch to `$.store`. `w.unsaved` is cleared when it goes
// through and, when it fails, says why and what a `later` session may do instead; that is also
// what this returns.
async function save(w: Watch, write: Promise<void>, later: string): Promise<string | null> {
  w.unsaved = await write.then(
    () => null,
    error => `could not be saved (${reason(error)}), so ${later}`,
  )
  return w.unsaved
}

function reason(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function cadence(w: Watch): string {
  return w.every > 0
    ? `a check every ${w.every} model steps while something draws the session`
    : 'automatic checks off (every = 0); /lookout now checks once'
}

function status(w: Watch): string {
  const lines = [
    w.isOff ? 'lookout: off (/lookout on turns it back on)' : `lookout: on, ${cadence(w)}`,
    ...(w.unsaved ? [`on/off setting: ${w.unsaved}`] : []),
    `last check: ${w.last}`,
    `checks this session: ${w.spent.checks} (prompt cache read ${thousands(w.spent.cacheRead)} tokens, ` +
      `cache write ${thousands(w.spent.cacheWrite)}, uncached input ${thousands(w.spent.input)}, ` +
      `output ${thousands(w.spent.output)})`,
  ]
  if (w.flags.length) lines.push('flags this session:', ...w.flags.map(flag => `- ${flag}`))
  return lines.join('\n')
}

// Whether anything draws this session: `$.session.surfaces()` is empty in a plain -p run and in a
// background job no client is attached to. An engine with no answer for it counts as unwatched:
// each fork reads the whole transcript, so lookout sends none it could not show.
export async function isWatched($: EngineInterface): Promise<boolean> {
  try {
    return (await $.session.surfaces()).length > 0
  } catch {
    return false
  }
}

// The one user message each fork answers. The fork carries the main thread's system prompt and
// transcript, so this says first that it is not a step of the task.
export function question(alreadyFlagged: readonly string[]): string {
  return [
    'This message comes from lookout, a plugin watching this session for the person running it. ' +
      'It is not from them and not a step of the task, and your reply goes to a note above their ' +
      'prompt, not into the conversation. Do not continue the task, do not call tools, and do not ' +
      'answer as the assistant.',
    '',
    'Read the conversation so far as a careful second pair of eyes. Is there one thing the person ' +
      'would want to know now and could easily miss? Only something that would change what they do, ' +
      'such as:',
    '- a command, test or check that failed, was skipped or was cut short while the work carried on as if it had passed',
    '- a guess or assumption stated as fact',
    '- a change beyond what was asked: other files, settings, branches, pushes, deletions, money spent or messages sent',
    '- work that goes against an instruction the person gave',
    '- a decision that is theirs to make being made without them',
    '- time or cost running well past what the task needs',
    '',
    'Leave out progress reports, anything the assistant already told the person plainly, and matters of style.',
    ...(alreadyFlagged.length
      ? ['Already flagged, so leave these out too:', ...alreadyFlagged.map(flag => `- ${flag}`)]
      : []),
    '',
    'Answer with exactly one line: `none`, or `Lookout: ` followed by what they should know, ' +
      'concrete and under 30 words.',
  ].join('\n')
}

/**
 * The flag in a fork's reply: the text after `Lookout:` on the first line that has it, `null` for
 * `none` (alone or as the flag), `undefined` for a reply in neither shape, which is not shown.
 */
export function parse(text: string): string | null | undefined {
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim().replace(/^[\s>*`"'-]+/, '').replace(/[\s`"']+$/, '')
    const labelled = /^lookout\s*:(.*)$/i.exec(line)
    if (labelled) {
      const flag = clean(labelled[1] ?? '')
      return flag === '' || NONE.test(flag) ? null : flag
    }
    if (NONE.test(line)) return null
  }
  return undefined
}

// Terminal escape sequences and control characters out, whitespace collapsed, cut to MAX_FLAG.
function clean(text: string): string {
  const plain = text
    .replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, '')
    .replace(/\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g, '')
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return plain.length > MAX_FLAG ? `${plain.slice(0, MAX_FLAG - 1).trimEnd()}…` : plain
}

// Two flags are the same when they differ only in case, spacing and punctuation.
function sameFlag(a: string, b: string): boolean {
  const key = (flag: string) => flag.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '')
  return key(a) === key(b)
}

function everyOf(value: unknown): number {
  const n = Math.floor(Number(value ?? DEFAULT_EVERY))
  return Number.isFinite(n) && n >= 0 ? Math.min(n, MAX_EVERY) : DEFAULT_EVERY
}

function thousands(n: number): string {
  return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}
