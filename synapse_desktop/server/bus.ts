// The Node host of the bus: a WebSocket on BUS_PATH is one connection, which says what this host can
// do and answers the messages of the frontend by the handlers below.

import type { IncomingMessage, Server } from 'node:http'
import { WebSocketServer, type WebSocket } from 'ws'
import { BUS_PATH, TOKEN_HEADER } from '../shared/constants.ts'
import { serve, type Connection } from '../shared/dispatch.ts'
import type { HostLink } from '../shared/link.ts'
import { type Capabilities } from '../shared/protocol.ts'
import { hostHandlers, type Context } from './calls.ts'
import { createTopics } from './topics.ts'
import { terminalHandlers, terminalStream } from './terminal-bus.ts'
import type { Sessions, Sink } from './terminal-sessions.ts'
import { checkUpgrade, type Policy } from './guards.ts'

// The one user this host serves, to whom a session belongs.
const LOCAL_USER = 'local'

export const nodeCapabilities: Capabilities = {
  host: 'node',
  shell: true,
  installActions: true,
}

// A WebSocket as the host's end of a Link: JSON in each direction.
export function socketLink(ws: WebSocket): HostLink {
  return {
    send(message) {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(message))
    },
    onMessage(handler) {
      const listener = (data: unknown) => {
        let parsed: unknown
        try {
          parsed = JSON.parse(String(data))
        } catch {
          return
        }
        handler(parsed as never)
      }
      ws.on('message', listener)
      return () => ws.off('message', listener)
    },
    onClose(handler) {
      ws.on('close', handler)
      return () => ws.off('close', handler)
    },
    close() {
      ws.close()
    },
  }
}

function header(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name]
  return Array.isArray(value) ? value[0] : value
}

export interface BusDeps {
  policy: Policy
  context: Context
  sessions: Sessions
  capabilities?: Capabilities
  report?: (error: unknown) => void
}

// Answers the WebSocket handshakes on BUS_PATH. Host, Origin and the token are checked once, at
// connect; a connection that passed is the page's own.
export function attachBus(server: Server, deps: BusDeps): void {
  const sockets = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 })
  const subscribe = createTopics({ context: deps.context })
  server.on('upgrade', (req, socket, head) => {
    if (req.url !== BUS_PATH) return
    const refusal = checkUpgrade(
      {
        host: header(req, 'host'),
        origin: header(req, 'origin'),
        token: header(req, TOKEN_HEADER),
      },
      deps.policy,
    )
    if (refusal !== null) {
      socket.write(`HTTP/1.1 ${refusal.status} Refused\r\nConnection: close\r\n\r\n`)
      socket.destroy()
      return
    }
    sockets.handleUpgrade(req, socket, head, (ws) => {
      const link = socketLink(ws)
      let connection: Connection | null = null
      // What a session prints goes to this connection's stream of it.
      const sink: Sink = { send: (session, message) => connection?.stream(session, message) }
      connection = serve(link, {
        handlers: {
          ...hostHandlers(deps.context),
          ...terminalHandlers(deps.sessions, LOCAL_USER, sink),
        },
        subscribe,
        onStream: terminalStream(deps.sessions, LOCAL_USER, sink),
        capabilities: deps.capabilities ?? nodeCapabilities,
        report: deps.report ?? ((error) => console.error(error)),
      })
      // A connection that goes leaves its sessions running.
      link.onClose(() => deps.sessions.detachAll(sink))
    })
  })
}
