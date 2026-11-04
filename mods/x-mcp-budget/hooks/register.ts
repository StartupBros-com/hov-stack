import type { EngineInterface, FsEntry, Register } from 'claude-code'

/**
 * x-mcp-budget: caps what Claude's X MCP reads cost.
 *
 * The hosted X MCP (api.x.com/mcp) bills pay-per-use: every post a call returns
 * is a post read, every user a user read, each counted once per UTC day per
 * app. The tools take a `max_results` that runs to 100 or more, and the account
 * has one spend limit shared by every app, so a few broad searches from an agent
 * session spend the same money as everything else on the account.
 *
 * Before an X MCP call runs, this mod:
 * - refuses it once today's estimated spend has reached the daily budget (UTC
 *   day; every session on this machine counts toward it), naming the reset and
 *   the free route for a single post;
 * - lowers a `max_results` above the cap to the cap, and gives the cap to a
 *   list, search or timeline tool that names none (X's own default page there
 *   can be 100).
 *
 * After it answers, the mod prices what came back: each post in `data` and
 * `includes.tweets` at POST_USD, each user in `data` at USER_USD (`includes.users`
 * from an author expansion bill nothing, measured). Each resource is recorded
 * once per UTC day in this session's own ledger file; today's spend is the union
 * of every session's file for the day, so a post two sessions read counts once,
 * as X counts it.
 *
 * It is an estimate, and a soft stop: the call that crosses the budget is
 * answered, a result the mod cannot read is not counted, and anything the mod
 * fails at lets the call run. The account's own spend limit is the hard stop.
 */

export const PREFIX = 'mcp__x__'
export const DEFAULT_DAILY_USD = 1
export const DEFAULT_MAX_RESULTS = 10
/** The lowest max_results every X MCP tool accepts: search_posts_all and get_posts_quoted_posts start at 10. */
export const MIN_MAX_RESULTS = 10
/** X pay-per-use prices: a post read and a user read. */
export const POST_USD = 0.005
export const USER_USD = 0.01
/** From this share of the budget on, each X MCP call's result says what today has spent. */
export const WARN_SHARE = 0.75

/**
 * The X MCP tools that return posts or users by the page. A call to one of
 * these with no max_results gets the cap. Any other X MCP tool's max_results
 * is lowered when it is over the cap, and never added.
 */
export const PAGED: ReadonlySet<string> = new Set([
  'get_lists_followers',
  'get_lists_members',
  'get_lists_posts',
  'get_posts_liking_users',
  'get_posts_quoted_posts',
  'get_posts_reposted_by',
  'get_spaces_posts',
  'get_users_blocking',
  'get_users_bookmarks',
  'get_users_bookmarks_by_folder_id',
  'get_users_liked_posts',
  'get_users_me_followers',
  'get_users_me_following',
  'get_users_mentions',
  'get_users_posts',
  'get_users_timeline',
  'search_posts_all',
  'search_users',
])

/** One billed resource a result returned: `post:<id>`, `user:<id>` or `item:<id>`, and its price. */
export type Priced = { key: string; usd: number }

/** A session's ledger file: resource key to its price, for one UTC day. */
type Ledger = Record<string, number>

/** The UTC day of a time, `YYYY-MM-DD`. */
export function dayOf(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10)
}

/** Time to the next 00:00 UTC, as `5h 30m`. */
export function untilReset(ms: number): string {
  const t = new Date(ms)
  const next = Date.UTC(t.getUTCFullYear(), t.getUTCMonth(), t.getUTCDate() + 1)
  const minutes = Math.max(1, Math.ceil((next - ms) / 60_000))
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`
}

export function budgetOf(value: unknown): number {
  const n = Number(value)
  return value !== undefined && value !== '' && Number.isFinite(n) && n >= 0 ? n : DEFAULT_DAILY_USD
}

export function maxResultsOf(value: unknown): number {
  const n = Math.floor(Number(value))
  return value !== undefined && value !== '' && Number.isFinite(n) ? Math.max(MIN_MAX_RESULTS, n) : DEFAULT_MAX_RESULTS
}

function priceOf(item: unknown): Priced | null {
  if (typeof item !== 'object' || item === null) return null
  const r = item as { id?: unknown; username?: unknown; text?: unknown }
  if (typeof r.id !== 'string' || r.id === '') return null // no id, no billed resource (usage, counts)
  if (typeof r.username === 'string' && typeof r.text !== 'string') return { key: `user:${r.id}`, usd: USER_USD }
  if (typeof r.text === 'string') return { key: `post:${r.id}`, usd: POST_USD }
  return { key: `item:${r.id}`, usd: POST_USD } // a list, space, story or chat event: priced like a post
}

/**
 * The billed resources in an X MCP result's text: `data` (one object or a
 * page) and `includes.tweets`. null when the text is not a JSON object.
 */
export function pricedIn(text: string): Priced[] | null {
  let body: unknown
  try {
    body = JSON.parse(text)
  } catch {
    return null
  }
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return null
  const b = body as { data?: unknown; includes?: { tweets?: unknown } }
  const data = Array.isArray(b.data) ? b.data : b.data === undefined ? [] : [b.data]
  const tweets = Array.isArray(b.includes?.tweets) ? b.includes.tweets : []
  const out: Priced[] = []
  for (const item of data) {
    const p = priceOf(item)
    if (p) out.push(p)
  }
  for (const item of tweets) {
    const p = priceOf(item)
    if (p) out.push({ key: p.key, usd: POST_USD })
  }
  return out
}

/** The text the model reads for a call: core's `text`, else a string result, else text content blocks. */
export function textOf(ran: { text?: string; result?: unknown }): string | null {
  if (typeof ran.text === 'string') return ran.text
  if (typeof ran.result === 'string') return ran.result
  if (Array.isArray(ran.result)) {
    const parts = ran.result
      .map(b => (typeof b === 'object' && b !== null && (b as { type?: unknown }).type === 'text' ? (b as { text?: unknown }).text : undefined))
      .filter((t): t is string => typeof t === 'string')
    return parts.length > 0 ? parts.join('') : null
  }
  return null
}

/** The ledger folder for a UTC day, or null when there is no home to keep it in. */
async function dirFor($: EngineInterface, day: string): Promise<string | null> {
  try {
    const xdg = await $.env.get('XDG_STATE_HOME')
    if (xdg !== undefined && xdg.startsWith('/')) return `${xdg}/x-mcp-budget/${day}`
    const home = (await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE'))
    return home === undefined || home === '' ? null : `${home.replace(/[\\/]+$/, '')}/.local/state/x-mcp-budget/${day}`
  } catch {
    return null
  }
}

async function readLedger($: EngineInterface, file: string): Promise<Ledger> {
  try {
    const parsed: unknown = JSON.parse((await $.fs.read(file)) as string)
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return {}
    const out: Ledger = {}
    for (const [k, v] of Object.entries(parsed)) if (typeof v === 'number' && Number.isFinite(v) && v > 0) out[k] = v
    return out
  } catch {
    return {} // missing, or caught mid-write by another process: counted on the next call
  }
}

/** Today's spend: every session's ledger for the day, each resource once. */
async function spentIn($: EngineInterface, dir: string): Promise<number> {
  let entries: FsEntry[]
  try {
    entries = await $.fs.list(dir)
  } catch {
    return 0 // no folder yet: nothing read today
  }
  const seen = new Map<string, number>()
  for (const entry of entries) {
    if (entry.kind !== 'file' || !entry.name.endsWith('.json')) continue
    for (const [k, v] of Object.entries(await readLedger($, `${dir}/${entry.name}`))) seen.set(k, Math.max(seen.get(k) ?? 0, v))
  }
  // Summed in millionths of a dollar: 200 posts at $0.005 come to exactly $1.00.
  let micro = 0
  for (const v of seen.values()) micro += Math.round(v * 1e6)
  return micro / 1e6
}

/** Adds what a call returned to this session's ledger for the day; resolves to the day's spend. */
async function record($: EngineInterface, dir: string, priced: readonly Priced[]): Promise<number> {
  const sid = (await $.session.id()).replace(/[^A-Za-z0-9_-]/g, '_') || 'session'
  const file = `${dir}/${sid}.json`
  const mine = await readLedger($, file)
  let changed = false
  for (const { key, usd } of priced) {
    if (key in mine) continue
    mine[key] = usd
    changed = true
  }
  if (changed) await $.fs.write(file, JSON.stringify(mine))
  return spentIn($, dir)
}

const usd = (n: number) => `$${n.toFixed(2)}`

export function denyText(spent: number, budget: number, day: string, now: number): string {
  const why =
    budget === 0
      ? 'the X MCP daily budget is $0, so this X MCP call was not sent'
      : `today's X MCP reads come to about ${usd(spent)}, the ${usd(budget)} daily budget (UTC day ${day}), so this X MCP call was not sent`
  return (
    `x-mcp-budget: ${why}. The budget resets at 00:00 UTC, in ${untilReset(now)}. ` +
    `Without the X MCP, one post's text and author are free from WebFetch of ` +
    `https://publish.x.com/oembed?url=<the post's x.com URL>. Raising the budget is the operator's call: ` +
    `pluginConfigs["x-mcp-budget"].options.dailyUsd in ~/.claude/settings.json.`
  )
}

export const register: Register = (on, options) => {
  const budget = budgetOf(options.dailyUsd)
  const cap = maxResultsOf(options.maxResults)
  // One module per process: subagents' calls share it, so ledger writes queue here.
  let queue: Promise<unknown> = Promise.resolve()
  const serial = <T>(fn: () => Promise<T>): Promise<T> => {
    const run = queue.then(fn, fn)
    queue = run.catch(() => undefined)
    return run
  }

  on('tool.call', async ($, e, next) => {
    if (!e.tool.startsWith(PREFIX)) return next(e)
    const name = e.tool.slice(PREFIX.length)
    const now = await $.clock.now()
    const day = dayOf(now)
    const dir = await dirFor($, day)
    const before = dir === null ? 0 : await spentIn($, dir)
    if (before >= budget) return { deny: denyText(before, budget, day, now) }

    const asked = (e as unknown as { max_results?: unknown }).max_results
    let input = e
    let paged = ''
    if (asked !== undefined && asked !== null) {
      const n = Number(asked)
      if (Number.isFinite(n) && n > cap) {
        input = { ...e, max_results: cap } as typeof e
        paged = `max_results ${n} was lowered to ${cap}`
      }
    } else if (PAGED.has(name)) {
      input = { ...e, max_results: cap } as typeof e
      paged = `max_results was set to ${cap} (none was given, and X's default page can be 100)`
    }

    const ran = await next(input)
    if (ran.deny !== undefined || ran.isError === true) return ran

    const text = textOf(ran)
    const priced = text === null ? null : pricedIn(text)
    let after = before
    let unrecorded = false
    if (priced !== null && priced.length > 0 && dir !== null) {
      try {
        after = await serial(() => record($, dir, priced))
      } catch {
        unrecorded = true
      }
    }

    const lines: string[] = []
    if (paged !== '') {
      lines.push(
        `x-mcp-budget: ${paged}. X bills $${POST_USD} for every post and $${USER_USD.toFixed(3)} for every user a page returns; ` +
          `page on with the next_token in meta only when the next page is worth it.`,
      )
    }
    if (priced === null && text !== null && text.trim() !== '') {
      lines.push('x-mcp-budget: this result is not the JSON the X API returns, so what it cost was not counted.')
    }
    if (unrecorded || (dir === null && priced !== null && priced.length > 0)) {
      lines.push('x-mcp-budget: the spend ledger could not be written, so what this call cost was not counted.')
    }
    if (after >= budget) {
      lines.push(
        `x-mcp-budget: today's X MCP reads now come to about ${usd(after)}, past the ${usd(budget)} daily budget; ` +
          `further X MCP calls are refused until 00:00 UTC (in ${untilReset(now)}).`,
      )
    } else if (paged !== '' || after >= budget * WARN_SHARE) {
      lines.push(`x-mcp-budget: today's X MCP reads come to about ${usd(after)} of the ${usd(budget)} daily budget (UTC day).`)
    }
    return lines.length === 0 ? ran : { ...ran, context: [...(ran.context ?? []), ...lines] }
  }).catch(($, e, next) => next(e)) // fail open: a ledger or parse failure never blocks the call
}
