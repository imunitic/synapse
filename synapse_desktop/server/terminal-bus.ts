// The terminal messages of one connection: its requests start, attach to, list and end sessions of
// the host, and what it streams is typed into and resized.

import { HostError, type Handlers } from '../shared/dispatch.ts'
import { terminalClientStreamSchema } from '../shared/terminal.ts'
import type { Sessions, Sink } from './terminal-sessions.ts'

export function terminalHandlers(sessions: Sessions, owner: string, sink: Sink): Handlers {
  return {
    'terminal.start': (params) => sessions.start(params, owner, sink),
    'terminal.attach': ({ session, cols, rows }) =>
      sessions.attach(session, owner, sink, { cols, rows }),
    'terminal.list': () => ({ sessions: sessions.list(owner) }),
    'terminal.close': ({ session }) => {
      sessions.close(session, owner)
      return null
    },
  }
}

// What the page types and the size it gives, for a session it is attached to.
export function terminalStream(
  sessions: Sessions,
  owner: string,
  sink: Sink,
): (session: string, data: unknown) => void {
  return (session, data) => {
    const parsed = terminalClientStreamSchema.safeParse(data)
    if (!parsed.success) return
    try {
      if (parsed.data.type === 'input') sessions.input(session, owner, sink, parsed.data.data)
      else sessions.resize(session, owner, sink, parsed.data.cols, parsed.data.rows)
    } catch (error) {
      // A stream of a session that is not there or not this user's says nothing back.
      if (!(error instanceof HostError)) throw error
    }
  }
}
