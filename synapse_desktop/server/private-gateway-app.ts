// One private gateway server for authenticated HTTP, protected Vite assets and WebSockets.
// Composition only: the operator still owns TLS, login, host mapping and listen().
import { createServer, type Server } from 'node:http'
import { attachSessionGateway, type SessionGatewayOptions } from './gateway-session-adapter.ts'
import { createProtectedFrontendHandler, type ProtectedAsset } from './gateway-protected-frontend.ts'
import { privateGatewayHttp } from './private-gateway-http.ts'

export interface PrivateGatewayAppOptions extends SessionGatewayOptions {
  readonly assets?: ReadonlyMap<string, ProtectedAsset>
}

export function createPrivateGatewayApp(options: PrivateGatewayAppOptions): Server {
  const sessionHandler = privateGatewayHttp(options.sessions)
  const frontendHandler = options.assets
    ? createProtectedFrontendHandler({
        publicHost: options.publicHost,
        sessions: options.sessions,
        assets: options.assets,
      })
    : null
  const server = createServer((request, response) => {
    if (request.url === '/api/session') {
      sessionHandler(request, response)
      return
    }
    if (request.url?.startsWith('/auth/')) {
      response.writeHead(404, { 'cache-control': 'no-store' })
      response.end()
      return
    }
    if (frontendHandler) {
      frontendHandler(request, response)
      return
    }
    response.writeHead(404, { 'cache-control': 'no-store' })
    response.end()
  })
  attachSessionGateway(server, options)
  return server
}
