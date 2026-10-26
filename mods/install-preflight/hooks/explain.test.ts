import { describe, expect, test } from 'claude-code/testing'

import { parseValidate, powersOf, rawLinesOf, summaryText, verdictOf } from './explain'
import type { ValidateReport } from './explain'
import { CALLS_LINE, HOOKS_LINE, LOOP_BREAKER_VALIDATE } from './fixtures'

const NONE = { settingsHooks: false, mcpServers: false }

function reportWith(...notes: string[]): ValidateReport {
  return {
    success: true,
    manifest: { errors: [], warnings: [], notes: [] },
    contents: [{ type: 'hooks', errors: [], warnings: [], notes }],
  }
}

describe('explain', () => {
  test('the live loop-breaker report parses and keeps its raw lines', async () => {
    const report = parseValidate(LOOP_BREAKER_VALIDATE)
    expect(report).not.toBeNull()
    expect(report?.success).toBe(true)
    expect(rawLinesOf(report!)).toEqual([HOOKS_LINE, CALLS_LINE])
  })

  test('loop-breaker reads as a mod that watches tool calls, with no high rows', async () => {
    const powers = powersOf(parseValidate(LOOP_BREAKER_VALIDATE)!, NONE)

    const sees = powers.find(p => p.text.includes('Sees every tool call'))
    expect(sees?.level).toBe('medium')
    expect(sees?.from).toEqual(['tool.call'])
    const stop = powers.find(p => p.text === 'Can stop a running turn')
    expect(stop?.level).toBe('info')
    expect(stop?.from).toEqual(['$.turn.abort'])
    expect(powers.filter(p => p.level === 'high')).toEqual([])
    expect(verdictOf(powers)).toBe('No high-risk powers found.')
  })

  test('draws and prompts are merged into one row each, listing every source', async () => {
    const powers = powersOf(parseValidate(LOOP_BREAKER_VALIDATE)!, NONE)
    const draws = powers.filter(p => p.text === 'Draws in the interface')
    expect(draws).toHaveLength(1)
    expect(draws[0]?.from).toEqual(['ui.render', '$.ui.resolve', '$.ui.toast'])
  })

  test('programs, internet and environment are three high rows named in the verdict', async () => {
    const report = reportWith('./register.tsx calls: $.process.run, $.http.fetch, $.env.get')
    const powers = powersOf(report, NONE)

    expect(powers.filter(p => p.level === 'high')).toHaveLength(3)
    expect(verdictOf(powers)).toBe(
      'Can start programs, reach the internet and read environment variables.',
    )
    expect(verdictOf(powers)).not.toMatch(/safe/i)
  })

  test('settings hooks in hooks.json add the shell-commands row', async () => {
    const report = reportWith('./register.tsx hooks: session.start')
    const powers = powersOf(report, { settingsHooks: true, mcpServers: true })

    const shell = powers.find(p => p.text.startsWith('Runs shell commands on events'))
    expect(shell?.level).toBe('high')
    expect(powers.find(p => p.text === 'Starts an MCP server of its own')?.level).toBe('medium')
    expect(verdictOf(powers)).toBe('Can run shell commands on events.')
  })

  test('matcher braces are stripped, even with a comma inside them', async () => {
    const report = reportWith(
      './register.tsx hooks: ui.render{component=Pane}, tool.check{tool=Bash,Read}, session.start',
    )
    const powers = powersOf(report, NONE)

    expect(powers.find(p => p.text === 'Draws in the interface')?.from).toEqual(['ui.render'])
    expect(powers.find(p => p.text.startsWith('Can approve or refuse'))?.from).toEqual(['tool.check'])
    expect(powers.find(p => p.text === 'Watches the session')?.from).toEqual(['session.start'])
  })

  test('unknown names fall through to a plain row, and fs writes outrank fs reads', async () => {
    const report = reportWith(
      './a.ts calls: $.fs.read, $.fs.write, $.widget.spin',
      './a.ts hooks: fs.read, mystery.event, classic.Stop',
    )
    const powers = powersOf(report, NONE)

    expect(powers.find(p => p.text === 'Can read files anywhere your account can')?.level).toBe('medium')
    expect(powers.find(p => p.text === 'Can create or overwrite files anywhere your account can')?.level).toBe('high')
    expect(powers.find(p => p.text === 'Calls $.widget.spin')?.level).toBe('info')
    expect(powers.find(p => p.text === 'Can see or change what other mods read, run or fetch')?.level).toBe('high')
    expect(powers.find(p => p.text === 'Hooks mystery.event')?.level).toBe('info')
    expect(powers.find(p => p.text === 'Also reacts to settings-hook events')?.level).toBe('info')
    expect(powers[0]?.level).toBe('high')
  })

  test('garbage and the wrong shape parse to null', async () => {
    expect(parseValidate('this is not json')).toBeNull()
    expect(parseValidate('')).toBeNull()
    expect(parseValidate('[]')).toBeNull()
    expect(parseValidate('{"success":true}')).toBeNull()
  })

  test('the transcript text lists powers with glyphs, the raw lines and the footer', async () => {
    const report = parseValidate(LOOP_BREAKER_VALIDATE)!
    const powers = powersOf(report, NONE)
    const text = summaryText(
      { name: 'loop-breaker', version: '0.1.0', author: 'StartupBros / House of Vibe' },
      powers,
      rawLinesOf(report),
    )

    expect(text).toContain('loop-breaker 0.1.0 by StartupBros / House of Vibe')
    expect(text).toContain('No high-risk powers found.')
    expect(text).toContain('~ Sees every tool call and can change or refuse it (from: tool.call)')
    expect(text).toContain('- Can stop a running turn')
    expect(text).toContain(HOOKS_LINE)
    expect(text).toContain(CALLS_LINE)
    expect(text).toContain('A list of powers, not a verdict. Read the code before you install')
  })
})
