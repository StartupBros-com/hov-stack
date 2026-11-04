import type { On } from 'claude-code'
import { describe, expect, test } from 'claude-code/testing'

import { POST_USD, USER_USD, budgetOf, dayOf, maxResultsOf, pricedIn, untilReset } from './register'

const SESSION = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const
const HOME = '/home/u'
// 2026-11-03 18:30 UTC: 5h 30m before the budget resets.
const NOW = Date.UTC(2026, 10, 3, 18, 30)
const DIR = `${HOME}/.local/state/x-mcp-budget/2026-11-03`
const MINE = `${DIR}/S1.json`

const post = (id: string) => ({ id, text: `post ${id}`, edit_history_tweet_ids: [id] })
const user = (id: string) => ({ id, name: `User ${id}`, username: `user${id}` })
/** A ledger file holding `n` posts other than the ones the tests read, worth n x POST_USD. */
const ledgerOf = (n: number, prefix = 'other') =>
  JSON.stringify(Object.fromEntries(Array.from({ length: n }, (_, i) => [`post:${prefix}${i}`, POST_USD])))

/**
 * The world beneath the mod: a file system in a Map, HOME, a session id, a
 * clock, and an X MCP tool that answers each call with `answer`'s JSON body.
 */
function world(
  on: On,
  opts: {
    files?: Record<string, string>
    now?: number
    home?: string
    answer?: (e: Record<string, unknown>) => unknown
    raw?: string
    isError?: boolean
    denyWith?: string
    failWrite?: boolean
  } = {},
) {
  const files = new Map(Object.entries(opts.files ?? {}))
  const seen: Array<Record<string, unknown>> = []
  const writes: string[] = []
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? ('home' in opts ? opts.home : HOME) : undefined }))
  on('session.id', () => ({ value: 'S1' }))
  on('clock.now', () => ({ value: opts.now ?? NOW }))
  on('fs.list', (_$, e) => {
    const prefix = `${e.path}/`
    const names = [...files.keys()].filter(p => p.startsWith(prefix) && !p.slice(prefix.length).includes('/'))
    if (names.length === 0) throw new Error(`ENOENT: ${e.path}`)
    return { value: names.map(p => ({ name: p.slice(prefix.length), kind: 'file' as const, size: 0, mtimeMs: 0, isLink: false })) }
  })
  on('fs.read', (_$, e) => {
    const text = files.get(e.path)
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    if (opts.failWrite) throw new Error('EACCES')
    files.set(e.path, e.text)
    writes.push(e.path)
    return { value: undefined }
  })
  on('tool.call', (_$, e) => {
    seen.push(e as unknown as Record<string, unknown>)
    // Any other tool is refused here, so no built-in tool's output schema is in play.
    if (!e.tool.startsWith('mcp__x__')) return { deny: 'world: not an X tool' }
    if (opts.denyWith !== undefined) return { deny: opts.denyWith }
    const text = opts.raw ?? JSON.stringify(opts.answer ? opts.answer(e as unknown as Record<string, unknown>) : { meta: { result_count: 0 } })
    return opts.isError ? { result: text, text, isError: true } : { result: text, text }
  })
  return { seen, files, writes }
}

const ledger = (files: Map<string, string>, path = MINE) => JSON.parse(files.get(path) ?? '{}') as Record<string, number>

describe('pricing', () => {
  test('posts and users in data are priced, includes.tweets as posts, includes.users not at all', () => {
    const body = { data: [post('1'), user('2')], includes: { users: [user('3')], tweets: [post('4')] }, meta: { result_count: 2 } }
    expect(pricedIn(JSON.stringify(body))).toEqual([
      { key: 'post:1', usd: POST_USD },
      { key: 'user:2', usd: USER_USD },
      { key: 'post:4', usd: POST_USD },
    ])
  })

  test('a single object in data counts once; an empty page, a body with no ids and non-JSON do not', () => {
    expect(pricedIn(JSON.stringify({ data: user('9') }))).toEqual([{ key: 'user:9', usd: USER_USD }])
    expect(pricedIn(JSON.stringify({ meta: { result_count: 0 } }))).toEqual([])
    expect(pricedIn(JSON.stringify({ data: { total_balance: '4.10' } }))).toEqual([])
    expect(pricedIn('Error: rate limited')).toBeNull()
    expect(pricedIn('[1,2]')).toBeNull()
  })

  test('options fall back to the defaults, and max_results never goes under 10', () => {
    expect(budgetOf(undefined)).toBe(1)
    expect(budgetOf(0)).toBe(0)
    expect(budgetOf(2.5)).toBe(2.5)
    expect(budgetOf(-1)).toBe(1)
    expect(budgetOf('x')).toBe(1)
    expect(maxResultsOf(undefined)).toBe(10)
    expect(maxResultsOf(5)).toBe(10)
    expect(maxResultsOf(25)).toBe(25)
  })

  test('the day and the reset are UTC', () => {
    expect(dayOf(NOW)).toBe('2026-11-03')
    expect(untilReset(NOW)).toBe('5h 30m')
    expect(dayOf(Date.UTC(2026, 10, 3, 23, 59, 59))).toBe('2026-11-03')
    expect(untilReset(Date.UTC(2026, 10, 3, 23, 59, 30))).toBe('0h 1m')
  })
})

describe('tool.call', () => {
  test('a search asking for 100 is sent asking for 10, and the result says so with the day so far', async ($, on) => {
    const w = world(on, { answer: () => ({ data: [post('1'), post('2')] }) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__search_posts_all', query: 'claude code', max_results: 100 })
    expect(w.seen).toHaveLength(1)
    expect(w.seen[0]?.max_results).toBe(10)
    expect(w.seen[0]?.query).toBe('claude code')
    expect(ran.context?.[0]).toContain('max_results 100 was lowered to 10')
    expect(ran.context?.[1]).toContain('about $0.01 of the $1.00 daily budget')
  })

  test('a paged tool with no max_results is given 10; one off the list is sent untouched', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await $.tool.call({ tool: 'mcp__x__get_users_posts', id: '123' })
    await $.tool.call({ tool: 'mcp__x__get_posts_by_ids', ids: '1,2,3' })
    expect(w.seen[0]?.max_results).toBe(10)
    expect('max_results' in (w.seen[1] ?? {})).toBe(false)
  })

  test('a max_results at or under the cap, and every other tool, pass untouched with no note', async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__search_posts_all', query: 'q', max_results: 10 })
    const bash = await $.tool.call({ tool: 'Bash', command: 'true' })
    expect(w.seen[0]?.max_results).toBe(10)
    expect(ran.context).toBeUndefined()
    expect(w.seen[1]).toEqual(expect.objectContaining({ tool: 'Bash', command: 'true' }))
    expect(bash.deny).toBe('world: not an X tool') // passed beneath untouched
    expect(w.writes).toHaveLength(0)
  })

  test('the maxResults option sets the cap', { options: { maxResults: 25 } }, async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    await $.tool.call({ tool: 'mcp__x__search_users', query: 'q', max_results: 100 })
    expect(w.seen[0]?.max_results).toBe(25)
  })

  test('each post and user is recorded once per UTC day in this session\'s ledger', async ($, on) => {
    let page = [post('1'), post('2'), user('3')]
    const w = world(on, { answer: () => ({ data: page }) })
    await $.session.start(SESSION)
    await $.tool.call({ tool: 'mcp__x__get_posts_by_ids', ids: '1,2' })
    expect(ledger(w.files)).toEqual({ 'post:1': POST_USD, 'post:2': POST_USD, 'user:3': USER_USD })
    page = [post('2'), post('5')]
    await $.tool.call({ tool: 'mcp__x__get_posts_by_ids', ids: '2,5' })
    expect(Object.keys(ledger(w.files)).sort()).toEqual(['post:1', 'post:2', 'post:5', 'user:3'])
  })

  test('a resource another session read today counts once toward the budget', async ($, on) => {
    // The other session holds 150 posts ($0.75), post 1 among them.
    const other = JSON.stringify({ ...JSON.parse(ledgerOf(149)), 'post:1': POST_USD })
    const w = world(on, { files: { [`${DIR}/S0.json`]: other }, answer: () => ({ data: [post('1')] }) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__get_posts_by_id', id: '1' })
    expect(ledger(w.files)).toEqual({ 'post:1': POST_USD })
    // Past 75% of the budget the result names the day so far: still $0.75, post 1 counted once.
    expect(ran.context?.at(-1)).toContain('about $0.75 of the $1.00 daily budget')
  })

  test('once today reaches the budget, X MCP calls are refused and none is sent', async ($, on) => {
    const w = world(on, { files: { [`${DIR}/S0.json`]: ledgerOf(120), [`${DIR}/S2.json`]: ledgerOf(80, 'more') } })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__search_posts_all', query: 'q' })
    expect(w.seen).toHaveLength(0)
    expect(ran.deny).toContain('about $1.00, the $1.00 daily budget (UTC day 2026-11-03)')
    expect(ran.deny).toContain('resets at 00:00 UTC, in 5h 30m')
    expect(ran.deny).toContain('https://publish.x.com/oembed?url=')
    expect(ran.deny).toContain('pluginConfigs["x-mcp-budget"].options.dailyUsd')
    // Other tools still run.
    await $.tool.call({ tool: 'Bash', command: 'true' })
    expect(w.seen).toHaveLength(1)
  })

  test('the call that crosses the budget is answered and says the rest are refused', async ($, on) => {
    const page = Array.from({ length: 10 }, (_, i) => post(`n${i}`))
    const w = world(on, { files: { [`${DIR}/S0.json`]: ledgerOf(194) }, answer: () => ({ data: page }) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__search_posts_all', query: 'q', max_results: 10 })
    expect(w.seen).toHaveLength(1)
    expect(ran.context?.at(-1)).toContain('now come to about $1.02, past the $1.00 daily budget')
    const refused = await $.tool.call({ tool: 'mcp__x__search_posts_all', query: 'q' })
    expect(refused.deny).toContain('daily budget')
    expect(w.seen).toHaveLength(1)
  })

  test('yesterday\'s spend does not count today', async ($, on) => {
    const w = world(on, { files: { [`${HOME}/.local/state/x-mcp-budget/2026-11-02/S0.json`]: ledgerOf(1_000) } })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__search_posts_all', query: 'q' })
    expect(ran.deny).toBeUndefined()
    expect(w.seen).toHaveLength(1)
  })

  test('a dailyUsd of 0 refuses every X MCP call', { options: { dailyUsd: 0 } }, async ($, on) => {
    const w = world(on)
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__get_posts_by_id', id: '20' })
    expect(w.seen).toHaveLength(0)
    expect(ran.deny).toContain('the X MCP daily budget is $0')
  })

  test('an errored call, a deny from beneath and an empty page are not counted', async ($, on) => {
    const failed = world(on, { isError: true, answer: () => ({ data: [post('1')] }) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__get_posts_by_id', id: '1' })
    expect(ran.isError).toBe(true)
    expect(failed.writes).toHaveLength(0)
  })

  test('a deny from beneath passes through as it was', async ($, on) => {
    world(on, { denyWith: 'not allowed' })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__search_posts_all', query: 'q' })
    expect(ran.deny).toBe('not allowed')
  })

  test('a result that is not JSON is passed through and named uncounted', async ($, on) => {
    const w = world(on, { raw: 'Too many requests' })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__get_posts_by_id', id: '1' })
    expect(ran.text).toBe('Too many requests')
    expect(ran.context?.[0]).toContain('not the JSON the X API returns')
    expect(w.writes).toHaveLength(0)
  })

  test('with no home or an unwritable ledger the call still runs, clamped, and says it was not counted', async ($, on) => {
    const w = world(on, { home: undefined, answer: () => ({ data: [post('1')] }) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__search_posts_all', query: 'q', max_results: 50 })
    expect(w.seen[0]?.max_results).toBe(10)
    expect(ran.context?.some(l => l.includes('could not be written'))).toBe(true)
  })

  test('a write that fails leaves the answer intact', async ($, on) => {
    const w = world(on, { failWrite: true, answer: () => ({ data: [post('1')] }) })
    await $.session.start(SESSION)
    const ran = await $.tool.call({ tool: 'mcp__x__get_posts_by_id', id: '1' })
    expect(JSON.parse(ran.text ?? '{}')).toEqual({ data: [post('1')] })
    expect(ran.context?.some(l => l.includes('could not be written'))).toBe(true)
    expect(w.seen).toHaveLength(1)
  })
})
