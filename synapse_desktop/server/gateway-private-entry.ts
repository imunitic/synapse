// Single HTTP dispatcher for the opt-in private PWA gateway.
// The caller owns the server lifecycle and HTTPS termination. No listener,
// user container or remote desktop host is started here.
import type { Server } from 'node:http'
import { attachSessionGateway, type SessionGatewayOptions } from './gateway-session-adapter.ts'
import { createGatewayHttpAuthHandler, type GatewayHttpAuthOptions } from './gateway-http-auth.ts'
import {
  createProtectedFrontendHandler,
  type ProtectedFrontendOptions,
} from './gateway-protected-frontend.ts'
import { createPasswordVerifier, type PasswordAccount } from './gateway-password-verifier.ts'
import { createTrustedPeerKey } from './gateway-trusted-peer.ts'

export interface PrivateGatewayOptions
  extends
    Pick<SessionGatewayOptions, 'hosts' | 'recheckMs' | 'maxConnectionsPerUser' | 'heartbeatMs' | 'flowOptions'>,
    Pick<ProtectedFrontendOptions, 'assets'>,
    Pick<GatewayHttpAuthOptions, 'maxAttempts' | 'attemptWindowMs' | 'maxTrackedPeers'> {
  readonly publicHost: string
  readonly publicOrigin: string
  readonly sessions: SessionGatewayOptions['sessions'] & GatewayHttpAuthOptions['sessions']
  readonly accounts: readonly PasswordAccount[]
  readonly trustedProxyAddresses?: readonly string[]
}

export function attachPrivateGateway(server: Server, options: PrivateGatewayOptions): void {
  // Multiple request listeners are invoked independently by Node. Do not
  // compose this dispatcher with a preexisting HTTP route handler.
  if (server.listenerCount('request') !== 0 || server.listenerCount('upgrade') !== 0) {
    throw new Error('private gateway requires an unclaimed HTTP server')
  }

  // Validate all operator configuration before registering any handlers.
  const verifyCredentials = createPasswordVerifier(options.accounts)
  const peerKey = createTrustedPeerKey(options.trustedProxyAddresses ?? [])
  const auth = createGatewayHttpAuthHandler({
    publicHost: options.publicHost,
    publicOrigin: options.publicOrigin,
    sessions: options.sessions,
    verifyCredentials,
    peerKey,
    maxAttempts: options.maxAttempts,
    attemptWindowMs: options.attemptWindowMs,
    maxTrackedPeers: options.maxTrackedPeers,
  })
  const frontend = createProtectedFrontendHandler({
    publicHost: options.publicHost,
    sessions: options.sessions,
    assets: options.assets,
  })

  server.on('request', (request, response) => {
    switch (request.url) {
      case '/auth/session':
      case '/auth/logout':
      case '/auth/me':
        auth(request, response)
        break
      default:
        frontend(request, response)
        break
    }
  })

  attachSessionGateway(server, {
    publicHost: options.publicHost,
    publicOrigin: options.publicOrigin,
    hosts: options.hosts,
    sessions: options.sessions,
    recheckMs: options.recheckMs,
    maxConnectionsPerUser: options.maxConnectionsPerUser,
    heartbeatMs: options.heartbeatMs,
    flowOptions: options.flowOptions,
  })
}
