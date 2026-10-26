import type { On } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import { CALLS_LINE, LOOP_BREAKER_VALIDATE, RISKY_VALIDATE } from './fixtures'
import { cloneDirOf } from './register'

const SESSION = { surface: 'terminal', isInteractive: true, cwd: '/work' } as const

const PANE = {
  plugin: 'install-preflight',
  surface: 'terminal',
  component: 'Pane',
  requestId: 'preflight',
  props: {
    title: 'Preflight',
    isFocused: false,
    bodyColumns: 100,
    placement: 'inline',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
  viewport: { columns: 120, rows: 40 },
} as const

const PLUGIN_JSON = JSON.stringify({
  name: 'loop-breaker',
  version: '0.1.0',
  author: { name: 'StartupBros / House of Vibe' },
})
const HOOKS_JSON = JSON.stringify({ modules: ['./register.tsx'] })
const MARKETPLACE_JSON = JSON.stringify({ plugins: [{ name: 'alpha' }, { name: 'beta' }, { name: 'gamma' }] })

type Spy = {
  runs: string[][]
  opens: unknown[]
  copies: string[]
  closes: Array<{ id: string }>
}

type Files = Record<string, string>

type Exit = { exitCode: number; stdout: string; stderr: string }

type WorldOptions = {
  /** What `claude plugin validate --json` prints. */
  validateOut?: string
  /** Answers every process.run instead of the default runner. */
  run?: (argv: string[]) => Exit
}

/** The world beneath the mod: a tiny file system, a process runner and a surface that answers. */
function world(on: On, files: Files, options: WorldOptions = {}): Spy {
  const spy: Spy = { runs: [], opens: [], copies: [], closes: [] }
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('fs.exists', (_$, e) => ({ value: e.path in files }))
  on('fs.read', (_$, e) => {
    const text = files[e.path]
    if (text === undefined) throw new Error(`no such file ${e.path}`)
    return { value: text }
  })
  on('process.run', (_$, e) => {
    const argv = [...e.argv]
    spy.runs.push(argv)
    const defaultOut = (): Exit => {
      if (argv[0] === 'claude') return { exitCode: 0, stdout: options.validateOut ?? '', stderr: '' }
      if (argv.includes('get-url')) return { exitCode: 0, stdout: `${REPO_URL}\n`, stderr: '' }
      return { exitCode: 0, stdout: '', stderr: '' }
    }
    const out: Exit = options.run ? options.run(argv) : defaultOut()
    return { value: { ...out, isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.open', (_$, e) => {
    spy.opens.push(e)
    return { value: { isPlaced: true } }
  })
  on('ui.close', (_$, e) => {
    spy.closes.push({ id: e.id })
    return { value: undefined }
  })
  on('ui.copy', (_$, e) => {
    spy.copies.push(e.text)
    return { value: { isCopied: true } }
  })
  on('ui.toast', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  return spy
}

const FOLDER_FILES: Files = {
  '/some/dir': '',
  '/some/dir/.claude-plugin/plugin.json': PLUGIN_JSON,
  '/some/dir/hooks/hooks.json': HOOKS_JSON,
}

const REPO_URL = 'https://github.com/owner/repo.git'
const CLONE = cloneDirOf(REPO_URL)
const CLONE_FILES: Files = {
  [`${CLONE}/.claude-plugin/plugin.json`]: PLUGIN_JSON,
  [`${CLONE}/hooks/hooks.json`]: HOOKS_JSON,
}

const run = (args: string) =>
  ({
    command: 'preflight',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 120 },
  }) as const

describe('register', () => {
  test('no argument answers with usage and runs nothing', async ($, on) => {
    const spy = world(on, {})
    await $.session.start(SESSION)

    const { text } = await $.command.run(run(''))
    expect(text).toContain('folder')
    expect(text).toContain('owner/repo')
    expect(text).toContain('git url')
    expect(spy.runs).toEqual([])
    expect(spy.opens).toEqual([])
  })

  test('a folder is validated, explained in text, and shown in the pane', async ($, on) => {
    const spy = world(on, FOLDER_FILES, { validateOut: LOOP_BREAKER_VALIDATE })
    await $.session.start(SESSION)

    const { text } = await $.command.run(run('/some/dir'))
    expect(text).toContain('loop-breaker')
    expect(text).toContain('Sees every tool call')
    expect(text).toContain(CALLS_LINE)
    expect(spy.runs).toEqual([['claude', 'plugin', 'validate', '--json', '/some/dir']])
    expect(spy.opens).toHaveLength(1)

    const ui = await $.ui.mount(PANE)
    expect(await ui.find({ type: 'Text', text: /loop-breaker 0.1.0 by StartupBros/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /No high-risk powers found/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /hooks: turn.start/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /not a verdict/ })).toBeDefined()

    await ui.press({ key: 'copy' })
    expect(spy.copies).toEqual(['claude --plugin-dir /some/dir'])
    await ui.press({ key: 'close' })
    expect(spy.closes).toEqual([{ id: 'preflight' }])
    await ui.unmount()
  })

  test('owner/repo is cloned shallow from github, then validated', async ($, on) => {
    const spy = world(on, CLONE_FILES, { validateOut: LOOP_BREAKER_VALIDATE })
    await $.session.start(SESSION)

    const { text } = await $.command.run(run('owner/repo'))
    const clone = spy.runs[0] ?? []
    expect(clone.slice(0, 4)).toEqual(['git', 'clone', '--depth', '1'])
    expect(clone).toContain(REPO_URL)
    expect(clone[clone.length - 1]).toBe(CLONE)
    expect(CLONE.startsWith('/tmp/install-preflight/')).toBe(true)
    expect(cloneDirOf('https://github.com/owner/repo_git')).not.toBe(CLONE)
    expect(spy.runs[1]?.slice(0, 4)).toEqual(['claude', 'plugin', 'validate', '--json'])
    expect(text).toContain('loop-breaker')

    const ui = await $.ui.mount(PANE)
    await ui.press({ key: 'copy' })
    expect(spy.copies[0]).toContain('/plugin marketplace add owner/repo')
    expect(spy.copies[0]).toContain('/plugin install loop-breaker@loop-breaker')
    expect(spy.copies[0]).toContain('edit the marketplace name')
    await ui.unmount()
  })

  test('a clone fetched earlier is refreshed to the current head, not cloned again', async ($, on) => {
    const spy = world(on, { ...CLONE_FILES, [CLONE]: '' }, { validateOut: LOOP_BREAKER_VALIDATE })
    await $.session.start(SESSION)

    const { text } = await $.command.run(run('owner/repo'))
    expect(spy.runs[0]).toEqual(['git', '-C', CLONE, 'remote', 'get-url', 'origin'])
    expect(spy.runs[1]).toEqual(['git', '-C', CLONE, 'fetch', '--depth', '1', '--quiet', 'origin'])
    expect(spy.runs[2]).toEqual(['git', '-C', CLONE, 'reset', '--hard', '--quiet', 'FETCH_HEAD'])
    expect(spy.runs[3]?.[0]).toBe('claude')
    expect(spy.runs.some(r => r[1] === 'clone')).toBe(false)
    expect(text).toContain('Refreshed the clone fetched earlier')
  })

  test('a clone of a different repository at that path is not refreshed; a fresh one is made beside it', async ($, on) => {
    mock.clock(on)
    const fresh = `${CLONE}-0`
    const spy = world(
      on,
      { [CLONE]: '', [`${fresh}/.claude-plugin/plugin.json`]: PLUGIN_JSON, [`${fresh}/hooks/hooks.json`]: HOOKS_JSON },
      {
        run: argv =>
          argv.includes('get-url')
            ? { exitCode: 0, stdout: 'https://github.com/someone/else.git\n', stderr: '' }
            : { exitCode: 0, stdout: argv[0] === 'claude' ? LOOP_BREAKER_VALIDATE : '', stderr: '' },
      },
    )
    await $.session.start(SESSION)

    await $.command.run(run('owner/repo'))
    expect(spy.runs.some(r => r.includes('fetch'))).toBe(false)
    const clone = spy.runs.find(r => r[1] === 'clone') ?? []
    expect(clone[clone.length - 1]).toBe(fresh)
  })

  test('a report validate marked as failed is never read as clean', async ($, on) => {
    const failed = JSON.stringify({
      success: false,
      strict: false,
      target: '/some/dir/.claude-plugin/plugin.json',
      manifest: {
        file: '/some/dir/.claude-plugin/plugin.json',
        type: 'plugin',
        errors: [{ path: 'hooks', message: 'hooks.json names no module', code: null }],
        warnings: [],
        notes: [],
      },
      contents: [],
    })
    const spy = world(on, FOLDER_FILES, { validateOut: failed })
    await $.session.start(SESSION)

    const { text } = await $.command.run(run('/some/dir'))
    expect(text?.startsWith('Validation failed (1 error): hooks.json names no module')).toBe(true)
    expect(text).toContain('error: hooks.json names no module')
    expect(text).not.toContain('No high-risk powers found.\nloop-breaker')
    expect(spy.opens).toHaveLength(1)

    const ui = await $.ui.mount(PANE)
    expect(await ui.find({ type: 'Text', text: /Validation failed/ })).toBeDefined()
    await ui.unmount()
  })

  test('a clone that cannot be refreshed is left alone and a fresh one is made beside it', async ($, on) => {
    mock.clock(on)
    const fresh = `${CLONE}-0`
    const spy = world(
      on,
      { [CLONE]: '', [`${fresh}/.claude-plugin/plugin.json`]: PLUGIN_JSON, [`${fresh}/hooks/hooks.json`]: HOOKS_JSON },
      {
        run: argv =>
          argv.includes('fetch')
            ? { exitCode: 128, stdout: '', stderr: 'fatal: not a git repository' }
            : { exitCode: 0, stdout: argv[0] === 'claude' ? LOOP_BREAKER_VALIDATE : '', stderr: '' },
      },
    )
    await $.session.start(SESSION)

    const { text } = await $.command.run(run('owner/repo'))
    const clone = spy.runs.find(r => r[1] === 'clone') ?? []
    expect(clone.slice(0, 4)).toEqual(['git', 'clone', '--depth', '1'])
    expect(clone[clone.length - 1]).toBe(fresh)
    expect(spy.runs.some(r => r.includes('reset'))).toBe(false)
    expect(text).toContain('loop-breaker')
  })

  test('a failed clone says so with the first line of git stderr', async ($, on) => {
    const spy = world(on, {}, {
      run: () => ({ exitCode: 128, stdout: '', stderr: 'fatal: repository not found\nmore detail' }),
    })
    await $.session.start(SESSION)

    const { text } = await $.command.run(run('owner/missing'))
    expect(text).toBe('Could not fetch https://github.com/owner/missing.git: fatal: repository not found')
    expect(spy.runs).toHaveLength(1)
    expect(spy.opens).toEqual([])
  })

  test('a marketplace repo lists its plugins and runs no validate', async ($, on) => {
    const spy = world(
      on,
      { '/some/market': '', '/some/market/.claude-plugin/marketplace.json': MARKETPLACE_JSON },
      { validateOut: LOOP_BREAKER_VALIDATE },
    )
    await $.session.start(SESSION)

    const { text } = await $.command.run(run('/some/market'))
    expect(text).toBe(
      'This is a marketplace with 3 plugins: alpha, beta, gamma. Run /preflight on one plugin folder or repo.',
    )
    expect(spy.runs).toEqual([])
    expect(spy.opens).toEqual([])
  })

  test('output that is not JSON is reported and the pane stays closed', async ($, on) => {
    const spy = world(on, FOLDER_FILES, { validateOut: 'Error: something broke\nstack' })
    await $.session.start(SESSION)

    const { text } = await $.command.run(run('/some/dir'))
    expect(text).toContain('Could not read the report')
    expect(text).toContain('Error: something broke')
    expect(spy.opens).toEqual([])
  })

  test('a mod that runs programs leads with the high verdict and marks the pane with !', async ($, on) => {
    const spy = world(on, FOLDER_FILES, { validateOut: RISKY_VALIDATE })
    await $.session.start(SESSION)

    const { text } = await $.command.run(run('/some/dir'))
    expect(
      text?.startsWith(
        'Can start programs, reach the internet, read environment variables and approve or refuse tool calls before you are asked.',
      ),
    ).toBe(true)
    expect(text).toContain('! Can start programs on your machine, with your permissions')
    expect(spy.opens).toHaveLength(1)

    const ui = await $.ui.mount(PANE)
    expect(await ui.find({ type: 'Text', text: '!' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Can start programs on your machine/ })).toBeDefined()
    await ui.unmount()
  })

  test('the pane asks for a /preflight before there is a report', async ($, on) => {
    world(on, {})
    await $.session.start(SESSION)

    const ui = await $.ui.mount(PANE)
    expect(await ui.find({ type: 'Text', text: /Run \/preflight/ })).toBeDefined()
    await ui.unmount()
  })
})
