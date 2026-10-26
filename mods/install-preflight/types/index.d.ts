/** One thing a plugin can do, in plain language, and where we saw it. */
export type Power = {
  level: 'high' | 'medium' | 'info'
  text: string
  /** The hooks and calls this power was read from, for example `$.process.run`. */
  from: string[]
}

/** Everything the pane and the transcript answer show for one preflight. */
export type Report = {
  dir: string
  source: 'folder' | 'repo'
  url: string | null
  name: string
  version: string
  author: string
  verdict: string
  powers: Power[]
  rawLines: string[]
  errors: string[]
  warnings: string[]
  installCommand: string
}

declare module 'claude-code' {
  interface PluginState {
    'install-preflight': {
      /** The last preflight, or null before the first /preflight. */
      report: Report | null
    }
  }
}
