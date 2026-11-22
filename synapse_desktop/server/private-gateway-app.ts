// One private gateway server for authenticated HTTP and WebSocket traffic.
// Composition only: the operator still owns TLS, login, host mapping and listen().
import { createServer, type Server } from 'node:http'
import { attachSessionGateway, type SessionGatewayOptions } from './gateway-session-adapter.ts'
import { privateGatewayHttp } from './private-gateway-http.ts'

export function createPrivateGatewayApp(options: SessionGatewayOptions): Server {
  const server = createServer(privateGatewayHttp(options.sessions))
  attachSessionGateway(server, options)
  return server
}
