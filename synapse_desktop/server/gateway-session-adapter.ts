// Connect the private gateway's existing WebSocket transport to its server-side
// session store. This does not issue sessions, serve a login page, or start a
// listener. The desktop/local Node paths remain independent.
import type { Server } from 'node:http'
import { attachGateway, type GatewayOptions } from './gateway.ts'
import type { createGatewaySessions } from './gateway-sessions.ts'

export type GatewaySessionSource = Pick<
  ReturnType<typeof createGatewaySessions>,
  'authenticate' | 'sessionValid'
>

export interface SessionGatewayOptions extends Omit<
  GatewayOptions,
  'authenticate' | 'sessionValid'
> {
  readonly sessions: GatewaySessionSource
}

export function attachSessionGateway(server: Server, options: SessionGatewayOptions): void {
  attachGateway(server, {
    publicHost: options.publicHost,
    publicOrigin: options.publicOrigin,
    hosts: options.hosts,
    recheckMs: options.recheckMs,
    maxConnectionsPerUser: options.maxConnectionsPerUser,
    heartbeatMs: options.heartbeatMs,
    flowOptions: options.flowOptions,
    authenticate: (request) => options.sessions.authenticate(request),
    sessionValid: (session) => options.sessions.sessionValid(session),
  })
}
