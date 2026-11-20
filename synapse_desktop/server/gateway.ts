// The remote PWA gateway transports Synapse's existing /api/bus WebSocket.
// It intentionally does not start a listener or create login sessions: its caller
// must supply a trusted server-side session lookup and operator-owned host map.
// The old localhost Node host and Tauri IPC are unaffected.
import type { IncomingMessage, Server } from 'node:http'
import type { Duplex } from 'node:stream'
import { WebSocket, WebSocketServer } from 'ws'
import { BUS_PATH, TOKEN_HEADER } from '../shared/constants.ts'
import { hostForPrincipal, RouteDenied, type PrivateHost } from './gateway-routing.ts'
import { attachGatewayFlow, type GatewayFlowOptions } from './gateway-flow-control.ts'
import { attachGatewayHeartbeat } from './gateway-heartbeat.ts'

export interface GatewaySession {
  readonly userId: string
  readonly sessionId: string
}

export interface GatewayHost extends PrivateHost {
  // Private, per-container handshake credential; never accept this from the browser.
  readonly backendToken: string
  readonly backendOrigin: string
}

export interface GatewayOptions {
  readonly publicHost: string
  readonly publicOrigin: string
  readonly hosts: ReadonlyMap<string, GatewayHost>
  // Must check an authenticated server-side session record, never a client user header.
  readonly authenticate: (request: IncomingMessage) => Promise<GatewaySession | null>
  // Must re-check revocation and expiry, not merely whether an ID still exists.
  readonly sessionValid: (session: GatewaySession) => Promise<boolean>
  readonly recheckMs?: number
  readonly maxConnectionsPerUser?: number
  readonly heartbeatMs?: number
  readonly flowOptions?: GatewayFlowOptions
}

function refusal(socket: Duplex, status: number): void {
  if (socket.destroyed) return
  const reason = status === 401 ? 'Unauthorized' : status === 403 ? 'Forbidden' : 'Bad Gateway'
  socket.end(`HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`)
}

function targetUrl(host: GatewayHost): string {
  const url = new URL(host.backend)
  if (
    !['http:', 'https:', 'ws:', 'wss:'].includes(url.protocol) ||
    url.username ||
    url.password ||
    (url.pathname !== '/' && url.pathname !== '') ||
    url.search ||
    url.hash ||
    !host.backendToken ||
    !host.backendOrigin
  ) {
    throw new RouteDenied()
  }
  url.protocol = url.protocol === 'https:' || url.protocol === 'wss:' ? 'wss:' : 'ws:'
  url.pathname = BUS_PATH
  return url.href
}

const MAX_FRAME = 1024 * 1024

// The caller serves the PWA over authenticated HTTPS on this same server and
// must attach this handler only to its *private* application gateway.
export function attachGateway(server: Server, options: GatewayOptions): void {
  const sockets = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME })
  const interval = options.recheckMs ?? 15_000
  const maxConnectionsPerUser = options.maxConnectionsPerUser ?? 2
  const activeByUser = new Map<string, number>()
  if (!Number.isSafeInteger(maxConnectionsPerUser) || maxConnectionsPerUser < 1) {
    throw new Error('invalid per-user connection limit')
  }
  if (!Number.isFinite(interval) || interval < 10) {
    throw new Error('invalid session check interval')
  }

  server.on('upgrade', (req, socket, head) => {
    if (req.url !== BUS_PATH) {
      socket.destroy()
      return
    }
    // Browsers send Origin for WebSocket; neither Origin nor Host is user identity.
    if (req.headers.host !== options.publicHost || req.headers.origin !== options.publicOrigin) {
      refusal(socket, 403)
      return
    }

    void (async () => {
      let session: GatewaySession | null
      try {
        session = await options.authenticate(req)
      } catch {
        refusal(socket, 401)
        return
      }
      if (session === null || !session.sessionId || !session.userId) {
        refusal(socket, 401)
        return
      }

      const verifiedSession = session
      let host: GatewayHost
      try {
        host = hostForPrincipal(session, options.hosts) as GatewayHost
        if (!(await options.sessionValid(verifiedSession))) {
          refusal(socket, 401)
          return
        }
      } catch {
        refusal(socket, 403)
        return
      }

      let target: string
      try {
        target = targetUrl(host)
      } catch {
        refusal(socket, 502)
        return
      }
      if (socket.destroyed) return
      if ((activeByUser.get(verifiedSession.userId) ?? 0) >= maxConnectionsPerUser) {
        refusal(socket, 403)
        return
      }
      activeByUser.set(verifiedSession.userId, (activeByUser.get(verifiedSession.userId) ?? 0) + 1)
      let released = false
      const release = () => {
        if (released) return
        released = true
        const count = (activeByUser.get(verifiedSession.userId) ?? 1) - 1
        if (count <= 0) activeByUser.delete(verifiedSession.userId)
        else activeByUser.set(verifiedSession.userId, count)
      }

      // Only gateway-generated headers travel to the backend. Browser cookies,
      // Authorization, Host, user IDs and chosen target URLs are never forwarded.
      let upstream: WebSocket
      try {
        upstream = new WebSocket(target, {
          origin: host.backendOrigin,
          headers: { [TOKEN_HEADER]: host.backendToken },
          handshakeTimeout: 5000,
          maxPayload: MAX_FRAME,
        })
      } catch {
        release()
        refusal(socket, 502)
        return
      }
      let completed = false
      const fail = () => {
        if (completed) return
        completed = true
        release()
        upstream.terminate()
        refusal(socket, 502)
      }
      const onSocketClose = () => {
        release()
        upstream.terminate()
      }
      socket.once('close', onSocketClose)
      upstream.once('error', fail)
      upstream.once('close', fail)
      upstream.once('open', () => {
        if (completed || socket.destroyed) {
          release()
          upstream.terminate()
          return
        }
        completed = true
        socket.off('close', onSocketClose)
        upstream.off('error', fail)
        upstream.off('close', fail)
        sockets.handleUpgrade(req, socket, head, (client) => {
          let closing = false
          let validating = false
          let stopFlow = () => {}
          let stopHeartbeat = () => {}
          const shut = () => {
            if (closing) return
            closing = true
            clearInterval(timer)
            stopFlow()
            stopHeartbeat()
            release()
            client.terminate()
            upstream.terminate()
          }
          client.on('close', shut)
          upstream.on('close', shut)
          client.on('error', shut)
          upstream.on('error', shut)
          stopFlow = attachGatewayFlow(client, upstream, shut, options.flowOptions)
          stopHeartbeat = attachGatewayHeartbeat(client, upstream, shut, options.heartbeatMs)
          const timer = setInterval(() => {
            if (closing) return
            if (validating) return
            validating = true
            void options
              .sessionValid(verifiedSession)
              .then((valid) => {
                if (!valid) shut()
              })
              .catch(shut)
              .finally(() => {
                validating = false
              })
          }, interval)
          timer.unref()
        })
      })
    })()
  })
}
