// Explicit composition for a privately provisioned PWA gateway.
// The caller supplies password hashes from a protected operator-managed
// source; this module never opens a port, loads secrets, or enables remote mode.
import type { Server } from 'node:http'
import { attachGatewayHttpAuth, type GatewayHttpAuthOptions } from './gateway-http-auth.ts'
import { createPasswordVerifier, type PasswordAccount } from './gateway-password-verifier.ts'

export interface ProvisionedGatewayAuthOptions extends Omit<
  GatewayHttpAuthOptions,
  'verifyCredentials'
> {
  readonly accounts: readonly PasswordAccount[]
}

export function attachProvisionedGatewayAuth(
  server: Server,
  options: ProvisionedGatewayAuthOptions,
): void {
  // Fail startup on missing, duplicate or malformed operator account records.
  const verifyCredentials = createPasswordVerifier(options.accounts)
  attachGatewayHttpAuth(server, {
    publicHost: options.publicHost,
    publicOrigin: options.publicOrigin,
    sessions: options.sessions,
    verifyCredentials,
    maxAttempts: options.maxAttempts,
    attemptWindowMs: options.attemptWindowMs,
    maxTrackedPeers: options.maxTrackedPeers,
  })
}
