declare module 'claude-code' {
  interface PluginState {
    'loop-breaker': {
      /** The worst run of identical failures seen this turn: 0 when calm. */
      worst: number
      /** The tool whose identical call was last refused, for the band. */
      lastTool: string | null
    }
  }
}
