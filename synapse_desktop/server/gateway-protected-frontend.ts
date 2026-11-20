// Detached authenticated frontend delivery for the future private PWA gateway.
// The operator provides a *fixed* build manifest: no URL-to-filesystem lookup,
// path traversal, directory listing, implicit index fallback, or dynamic proxy.
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import type { createGatewaySessions } from './gateway-sessions.ts'

type SessionStore = Pick<ReturnType<typeof createGatewaySessions>, 'authenticate'>

export interface ProtectedAsset {
  readonly content: Buffer | string
  readonly contentType: string
}

export interface ProtectedFrontendOptions {
  readonly publicHost: string
  readonly sessions: SessionStore
  readonly assets: ReadonlyMap<string, ProtectedAsset>
}

const RESERVED = ['/auth/session', '/auth/logout', '/auth/me', '/api/bus']

function validPath(path: string): boolean {
  return (
    path.startsWith('/') &&
    path.length <= 1024 &&
    !path.includes('?') &&
    !path.includes('#') &&
    !path.includes('\\') &&
    !path.includes('%') &&
    !path.includes('//') &&
    !path.includes('/./') &&
    !path.includes('/../') &&
    !path.endsWith('/.') &&
    !path.endsWith('/..') &&
    !/[^\x20-\x7e]/.test(path)
  )
}

export function createProtectedFrontendHandler(options: ProtectedFrontendOptions) {
  if (options.assets.size === 0 || !options.assets.has('/')) {
    throw new Error('missing protected frontend index')
  }
  for (const [path, asset] of options.assets) {
    if (
      !validPath(path) ||
      RESERVED.includes(path) ||
      path.startsWith('/auth/') ||
      path.startsWith('/api/') ||
      !asset.contentType ||
      /[\r\n]/.test(asset.contentType)
    ) {
      throw new Error('invalid protected frontend manifest')
    }
  }

  return (request: IncomingMessage, response: ServerResponse) => {
    const path = request.url ?? ''
    // Only the three auth endpoints have a separate HTTP request handler.
    // The WebSocket bus is handled by an upgrade listener, not plain HTTP.
    if (RESERVED.includes(path) && path !== '/api/bus') return

    const respond = (status: number, body = '') => {
      response.writeHead(status, {
        'Content-Type': 'text/plain; charset=utf-8',
        'Content-Length': Buffer.byteLength(body),
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      })
      response.end(body)
    }

    if (request.headers.host !== options.publicHost) {
      respond(403)
      return
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      respond(405)
      return
    }
    if (!validPath(path)) {
      respond(404)
      return
    }

    void (async () => {
      try {
        // Navigation and static asset requests often have no Origin header.
        // They must rely on the exact Host and an authenticated HttpOnly cookie.
        const session = await options.sessions.authenticate(request)
        if (!session) {
          respond(401)
          return
        }
        const asset = options.assets.get(path)
        if (!asset) {
          respond(404)
          return
        }
        const bytes = Buffer.isBuffer(asset.content) ? asset.content : Buffer.from(asset.content)
        response.writeHead(200, {
          'Content-Type': asset.contentType,
          'Content-Length': bytes.length,
          'Cache-Control': 'private, no-store',
          'X-Content-Type-Options': 'nosniff',
          'Content-Security-Policy':
            "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'",
        })
        response.end(request.method === 'HEAD' ? undefined : bytes)
      } catch {
        if (!response.headersSent && !response.destroyed) respond(503)
      }
    })()
  }
}

export function attachProtectedFrontend(server: Server, options: ProtectedFrontendOptions): void {
  server.on('request', createProtectedFrontendHandler(options))
}
