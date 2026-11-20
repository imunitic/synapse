// Private gateway HTTP auth endpoints. This file never starts a public listener.
// The operator MUST provide a secure, externally configured credentials verifier.
// Do not mount these handlers on the existing localhost Node or Tauri hosts.
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import { createLoginLimiter } from './gateway-login-limiter.ts'
import { VERIFIER_BUSY } from './gateway-password-verifier.ts'
import {
  clearSessionCookie,
  createGatewaySessions,
  sessionCookie,
  sessionTokenFromCookie,
} from './gateway-sessions.ts'

type SessionStore = ReturnType<typeof createGatewaySessions>

export interface GatewayHttpAuthOptions {
  readonly publicHost: string
  readonly publicOrigin: string
  readonly sessions: SessionStore
  // Return a trusted, fixed user ID or null. Never trust the submitted username
  // as an authenticated identity without checking its credential.
  readonly verifyCredentials: (
    username: string,
    password: string,
  ) => Promise<string | null | typeof VERIFIER_BUSY>
  // The configured reverse proxy must validate and replace forwarding headers.
  // Never select a key directly from an arbitrary client-supplied header.
  readonly peerKey?: (request: IncomingMessage) => string | null
  readonly maxAttempts?: number
  readonly attemptWindowMs?: number
  readonly maxTrackedPeers?: number
}

function respond(response: ServerResponse, status: number, body: object, cookie?: string): void {
  const payload = JSON.stringify(body)
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...(cookie === undefined ? {} : { 'Set-Cookie': cookie }),
  })
  response.end(payload)
}

async function readCredentials(
  request: IncomingMessage,
): Promise<{ username: string; password: string } | null> {
  if (request.headers['content-type']?.split(';')[0]?.trim().toLowerCase() !== 'application/json')
    return null
  const chunks: Buffer[] = []
  let size = 0
  // Total read deadline, not merely an idle-socket timeout. Closing a slow
  // request releases the parser; no login verification runs on a partial body.
  const deadline = setTimeout(() => request.destroy(), 10_000)
  deadline.unref()
  try {
    for await (const part of request) {
      const chunk = Buffer.isBuffer(part) ? part : Buffer.from(part as Uint8Array)
      size += chunk.length
      if (size > 4096) {
        request.destroy()
        return null
      }
      chunks.push(chunk)
    }
  } finally {
    clearTimeout(deadline)
  }
  try {
    const value: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return null
    const fields = value as Record<string, unknown>
    if (
      typeof fields.username !== 'string' ||
      typeof fields.password !== 'string' ||
      fields.username.length < 1 ||
      fields.username.length > 128 ||
      fields.password.length < 1 ||
      fields.password.length > 1024
    )
      return null
    return { username: fields.username, password: fields.password }
  } catch {
    return null
  }
}

export function createGatewayHttpAuthHandler(options: GatewayHttpAuthOptions) {
  let lastPeerWarningAt = Number.NEGATIVE_INFINITY
  const limiter = createLoginLimiter({
    maxAttempts: options.maxAttempts ?? 5,
    windowMs: options.attemptWindowMs ?? 60_000,
    maxPeers: options.maxTrackedPeers ?? 1024,
  })
  return (request: IncomingMessage, response: ServerResponse) => {
    if (!['/auth/session', '/auth/logout', '/auth/me'].includes(request.url ?? '')) return

    if (
      request.headers.host !== options.publicHost ||
      (request.method !== 'GET' && request.headers.origin !== options.publicOrigin) ||
      (request.method === 'GET' &&
        request.headers.origin !== undefined &&
        request.headers.origin !== options.publicOrigin)
    ) {
      respond(response, 403, { error: 'forbidden' })
      return
    }

    void (async () => {
      try {
        if (request.url === '/auth/session') {
          if (request.method !== 'POST') {
            respond(response, 405, { error: 'method_not_allowed' })
            return
          }
          const peer = options.peerKey ? options.peerKey(request) : request.socket.remoteAddress
          if (!peer) {
            // Do not echo the malformed forwarded header or other request
            // secrets into logs. A missing trusted client identity is an
            // operator/proxy failure, not a rate-limit violation.
            const time = Date.now()
            if (time - lastPeerWarningAt >= 60_000) {
              lastPeerWarningAt = time
              console.error('Synapse gateway: missing or invalid trusted client address')
            }
            respond(response, 503, { error: 'service_unavailable' })
            return
          }
          if (!limiter.allow(peer)) {
            respond(response, 429, { error: 'too_many_attempts' })
            return
          }
          const credentials = await readCredentials(request)
          if (!credentials) {
            if (!response.destroyed) respond(response, 400, { error: 'invalid_request' })
            return
          }
          // A verifier must establish identity independently of the browser.
          const userId = await options.verifyCredentials(credentials.username, credentials.password)
          if (userId === VERIFIER_BUSY) {
            respond(response, 503, { error: 'service_busy' })
            return
          }
          if (!userId) {
            respond(response, 401, { error: 'invalid_credentials' })
            return
          }
          const issued = options.sessions.issue(userId)
          respond(response, 200, { authenticated: true }, sessionCookie(issued.token))
          return
        }
        if (request.url === '/auth/logout') {
          if (request.method !== 'POST') {
            respond(response, 405, { error: 'method_not_allowed' })
            return
          }
          const token = sessionTokenFromCookie(request.headers.cookie)
          if (token !== null) options.sessions.revoke(token)
          respond(response, 200, { authenticated: false }, clearSessionCookie())
          return
        }
        if (request.method !== 'GET') {
          respond(response, 405, { error: 'method_not_allowed' })
          return
        }
        const session = await options.sessions.authenticate(request)
        respond(
          response,
          session === null ? 401 : 200,
          session === null ? { authenticated: false } : { authenticated: true },
        )
      } catch {
        if (!response.headersSent && !response.destroyed) {
          respond(response, 503, { error: 'service_unavailable' })
        }
      }
    })()
  }
}

export function attachGatewayHttpAuth(server: Server, options: GatewayHttpAuthOptions): void {
  server.on('request', createGatewayHttpAuthHandler(options))
}
