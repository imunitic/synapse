// Opt-in private gateway, loopback by default. No default accounts or secrets.
// An operator supplies an external JSON config and an already-built frontend.
import { readFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { resolve } from 'node:path'
import { attachPrivateGateway } from './gateway-private-entry.ts'
import { createGatewaySessions } from './gateway-sessions.ts'
import { loadViteProtectedAssets } from './gateway-vite-assets.ts'
import type { GatewayHost } from './gateway.ts'
import type { PasswordAccount } from './gateway-password-verifier.ts'
import { isPrivateBackendUrl } from './private-network-bind.ts'
import { privateGatewayBind } from './private-gateway-bind.ts'

interface PrivateGatewayConfig {
  readonly port: number
  readonly publicHost: string
  readonly publicOrigin: string
  readonly buildDirectory: string
  readonly trustedProxyAddresses?: readonly string[]
  readonly accounts: PasswordAccount[]
  readonly hosts: GatewayHost[]
}

function validateConfig(value: unknown): PrivateGatewayConfig {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('invalid private gateway configuration')
  }
  const config = value as PrivateGatewayConfig
  if (!Number.isSafeInteger(config.port) || config.port < 1 || config.port > 65535) {
    throw new Error('invalid private gateway port')
  }
  const origin = new URL(config.publicOrigin)
  if (
    origin.protocol !== 'https:' ||
    origin.origin !== config.publicOrigin ||
    origin.host !== config.publicHost
  ) {
    throw new Error('private gateway requires an exact HTTPS public Origin')
  }
  if (!config.buildDirectory || typeof config.buildDirectory !== 'string') {
    throw new Error('private gateway build directory required')
  }
  if (!Array.isArray(config.accounts) || !Array.isArray(config.hosts)) {
    throw new Error('private gateway accounts and hosts required')
  }
  if (config.hosts.length !== config.accounts.length) {
    throw new Error('each gateway account requires an isolated private host')
  }
  if (config.trustedProxyAddresses !== undefined && !Array.isArray(config.trustedProxyAddresses)) {
    throw new Error('trusted proxy addresses must be an array')
  }
  const accountIds = new Set(config.accounts.map((account) => account.userId))
  const hostIds = new Set(config.hosts.map((host) => host.userId))
  if (
    accountIds.size !== config.accounts.length ||
    hostIds.size !== config.hosts.length ||
    [...accountIds].some((userId) => !hostIds.has(userId))
  ) {
    throw new Error('gateway account and private host IDs must match exactly')
  }
  for (const host of config.hosts) {
    const backend = new URL(host.backend)
    if (!isPrivateBackendUrl(backend) || !host.backendToken || !host.backendOrigin) {
      throw new Error('private host must use a loopback or RFC1918 IPv4 backend')
    }
  }
  return config
}

async function main(): Promise<void> {
  const path = process.env.SYNAPSE_PRIVATE_GATEWAY_CONFIG
  if (!path) throw new Error('SYNAPSE_PRIVATE_GATEWAY_CONFIG is required')
  const config = validateConfig(JSON.parse(await readFile(resolve(path), 'utf8')) as unknown)
  const assets = await loadViteProtectedAssets(resolve(config.buildDirectory))
  const sessions = createGatewaySessions()
  const server = createServer()
  attachPrivateGateway(server, {
    publicHost: config.publicHost,
    publicOrigin: config.publicOrigin,
    sessions,
    accounts: config.accounts,
    trustedProxyAddresses: config.trustedProxyAddresses,
    hosts: new Map(config.hosts.map((host) => [host.userId, host])),
    assets,
  })
  const bindAddress = privateGatewayBind(process.env)
  server.once('error', () => {
    console.error('private gateway listener failed; check bind address and port')
    process.exitCode = 1
    server.close()
  })
  server.listen(config.port, bindAddress, () => {
    console.log(`private Synapse gateway listening on ${bindAddress}:${config.port}`)
  })
}

void main().catch(() => {
  console.error('private gateway startup failed; check configuration and frontend assets')
  process.exitCode = 1
})
