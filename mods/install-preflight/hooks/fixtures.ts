/**
 * A live `claude plugin validate --json` run on the loop-breaker mod (Claude Code 2.1.287),
 * kept verbatim so the tests read the real shape rather than one we imagined.
 */
export const LOOP_BREAKER_VALIDATE = `{
  "success": true,
  "strict": false,
  "target": "/home/user/.claude/dev-mods/a6eda6ea-ef3d-4cb1-8ba6-a3891704429e/loop-breaker/.claude-plugin/plugin.json",
  "manifest": {
    "file": "/home/user/.claude/dev-mods/a6eda6ea-ef3d-4cb1-8ba6-a3891704429e/loop-breaker/.claude-plugin/plugin.json",
    "type": "plugin",
    "errors": [],
    "warnings": [],
    "notes": [
      "types ./types/index.d.ts declares on $: nothing (no EngineInterface member)",
      "types ./types/index.d.ts declares state: loop-breaker.worst, loop-breaker.lastTool"
    ]
  },
  "contents": [
    {
      "file": "/home/user/.claude/dev-mods/a6eda6ea-ef3d-4cb1-8ba6-a3891704429e/loop-breaker/hooks/hooks.json",
      "type": "hooks",
      "errors": [],
      "warnings": [],
      "notes": [
        "./register.tsx hooks: turn.start, turn.complete, tool.call, ui.render{component=AbovePrompt}",
        "./register.tsx calls: $.prompt.submit, $.state.get, $.state.set, $.turn.abort, $.ui.resolve, $.ui.toast",
        "./register.tsx state writes: loop-breaker.lastTool, loop-breaker.worst",
        "./register.tsx state reads: loop-breaker.lastTool, loop-breaker.worst"
      ]
    }
  ]
}`

export const HOOKS_LINE =
  './register.tsx hooks: turn.start, turn.complete, tool.call, ui.render{component=AbovePrompt}'
export const CALLS_LINE =
  './register.tsx calls: $.prompt.submit, $.state.get, $.state.set, $.turn.abort, $.ui.resolve, $.ui.toast'

/** The same shape with a module that runs programs, reaches the internet and reads the environment. */
export const RISKY_VALIDATE = JSON.stringify({
  success: true,
  strict: false,
  target: '/some/dir/.claude-plugin/plugin.json',
  manifest: { file: '/some/dir/.claude-plugin/plugin.json', type: 'plugin', errors: [], warnings: [], notes: [] },
  contents: [
    {
      file: '/some/dir/hooks/hooks.json',
      type: 'hooks',
      errors: [],
      warnings: [],
      notes: [
        './register.tsx hooks: session.start, tool.check, ui.render{component=Pane}',
        './register.tsx calls: $.process.run, $.http.fetch, $.env.get',
      ],
    },
  ],
})
