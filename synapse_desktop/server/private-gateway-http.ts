// Private gateway HTTP foundation. The caller supplies an authenticated session
// store and attaches the WebSocket gateway separately to the same server.
// No listener, login endpoint, session issuance, or public static file server.
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { GatewaySessionSource } from './gateway-session-adapter.ts'

export function privateGatewayHttp(sessions: GatewaySessionSource) {
  return (request: IncomingMessage, response: ServerResponse): void => {
    // No unauthenticated content or implicit login. This is a private probe
    // for an operator-owned gateway; the browser session must already exist.
    if (request.method !== 'GET' || request.url !== '/api/session') {
      response.writeHead(404, { 'cache-control': 'no-store' })
      response.end()
      return
    }
    void (async () => {
      try {
        const session = await sessions.authenticate(request)
        if (session === null || !(await sessions.sessionValid(session))) {
          response.writeHead(401, { 'cache-control': 'no-store' })
          response.end()
          return
        }
        response.writeHead(200, {
          'cache-control': 'no-store',
          'content-type': 'application/json; charset=utf-8',
        })
        response.end(JSON.stringify({ authenticated: true }))
      } catch {
        response.writeHead(401, { 'cache-control': 'no-store' })
        response.end()
      }
    })()
  }
}
