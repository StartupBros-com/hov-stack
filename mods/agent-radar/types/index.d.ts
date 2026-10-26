export type RadarAgent = {
  id: string
  description: string
  type: string
  // `ended`: delegated work whose process is gone; how it went is not the radar's to know.
  status: 'running' | 'done' | 'failed' | 'ended'
  startedAt: number
  endedAt?: number
  tools: number
  last: string
  // Taken from the engine's own list after it had started: startedAt is the adoption time.
  adopted?: boolean
  // Delegated work outside the session (../hooks/delegates.ts): its process, and the directory
  // it runs in when that could be read.
  pid?: number
  cwd?: string
}

declare module 'claude-code' {
  interface PluginState {
    // `sessions`: every session id the conversation has had in this process (a resume starts it
    // over), so work started before a /clear stays in view.
    'agent-radar': { agents: RadarAgent[]; selected: string | null; now: number; seen: string[]; sessions: string[] }
  }
}
