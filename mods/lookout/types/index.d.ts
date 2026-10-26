declare module 'claude-code' {
  interface PluginState {
    lookout: {
      /** The flag shown above the prompt; null when there is none. */
      card: string | null
    }
  }
}
