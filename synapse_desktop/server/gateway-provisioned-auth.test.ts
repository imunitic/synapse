import { createServer, type Server } from 'node:http'
import { afterEach, describe, expect, it } from 'vitest'
import { attachProvisionedGatewayAuth } from './gateway-provisioned-auth.ts'
import { hashGatewayPassword } from './gateway-password-verifier.ts'
import { createGatewaySessions } from './gateway-sessions.ts'

const ORIGIN = 'https://synapse.example.test'
const servers: Server[] = []

afterEach(async () => {
  await Promise.all(
    servers.map(
      (server) =>
        new Promise<void>((resolve) => {
          server.closeAllConnections()
          server.close(() => resolve())
        }),
    ),
  )
  servers.length = 0
})

describe('provisioned gateway authentication', () => {
  it('validates an operator-provisioned hash through HTTP and uses its fixed user ID', async () => {
    const server = createServer()
    servers.push(server)
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    const address = server.address()
    if (address === null || typeof address === 'string') throw new Error('invalid address')
    const host = `127.0.0.1:${address.port}`
    const sessions = createGatewaySessions()
    const passwordHash = await hashGatewayPassword('fixture-long-password')
    attachProvisionedGatewayAuth(server, {
      publicHost: host,
      publicOrigin: ORIGIN,
      sessions,
      accounts: [{ username: 'alice', userId: 'user-alice', passwordHash }],
    })
    const login = async (password: string) =>
      fetch(`http://${host}/auth/session`, {
        method: 'POST',
        headers: { Origin: ORIGIN, 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: 'alice', password }),
      })
    const refused = await login('not-the-password')
    expect(refused.status).toBe(401)
    const accepted = await login('fixture-long-password')
    expect(accepted.status).toBe(200)
    const cookie = (accepted.headers.get('set-cookie') ?? '').split(';')[0] ?? ''
    const status = await fetch(`http://${host}/auth/me`, {
      headers: { Origin: ORIGIN, Cookie: cookie },
    })
    expect(status.status).toBe(200)
    const logout = await fetch(`http://${host}/auth/logout`, {
      method: 'POST',
      headers: { Origin: ORIGIN, Cookie: cookie },
    })
    expect(logout.status).toBe(200)
    const rejected = await fetch(`http://${host}/auth/me`, {
      headers: { Origin: ORIGIN, Cookie: cookie },
    })
    expect(rejected.status).toBe(401)
  })

  it('rejects malformed external credentials at configuration time', () => {
    const server = createServer()
    servers.push(server)
    expect(() =>
      attachProvisionedGatewayAuth(server, {
        publicHost: 'synapse.example.test',
        publicOrigin: ORIGIN,
        sessions: createGatewaySessions(),
        accounts: [{ username: 'alice', userId: 'user-alice', passwordHash: 'plaintext' }],
      }),
    ).toThrow()
  })
})
