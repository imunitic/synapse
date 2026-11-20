import { createServer, type Server } from 'node:http'
import { afterEach, describe, expect, it } from 'vitest'
import { attachPrivateGateway } from './gateway-private-entry.ts'
import { hashGatewayPassword } from './gateway-password-verifier.ts'
import { createGatewaySessions } from './gateway-sessions.ts'

const ORIGIN = 'https://synapse.example.test'
const servers: Server[] = []

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise<void>((resolve) => {
          server.closeAllConnections()
          server.close(() => resolve())
        }),
    ),
  )
})

describe('private PWA gateway HTTP composition', () => {
  it('has a single HTTP listener and routes login, protected assets and logout safely', async () => {
    const server = createServer()
    servers.push(server)
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    const address = server.address()
    if (!address || typeof address === 'string') throw new Error('invalid test address')
    const host = `127.0.0.1:${address.port}`
    const sessions = createGatewaySessions()
    attachPrivateGateway(server, {
      publicHost: host,
      publicOrigin: ORIGIN,
      sessions,
      accounts: [
        {
          username: 'alice',
          userId: 'alice',
          passwordHash: await hashGatewayPassword('fixture-password-long'),
        },
      ],
      hosts: new Map(),
      assets: new Map([
        ['/', { content: '<html>private</html>', contentType: 'text/html' }],
        ['/assets/app.js', { content: 'console.log("private")', contentType: 'text/javascript' }],
      ]),
    })
    expect(server.listenerCount('request')).toBe(1)
    expect(server.listenerCount('upgrade')).toBe(1)
    const request = (path: string, options: RequestInit = {}) =>
      fetch(`http://${host}${path}`, options)
    expect((await request('/')).status).toBe(401)
    expect((await request('/assets/app.js')).status).toBe(401)
    expect((await request('/auth/me', { headers: { Origin: ORIGIN } })).status).toBe(401)
    expect((await request('/api/bus')).status).toBe(401)
    expect(
      (
        await request('/auth/session', {
          method: 'POST',
          headers: { Origin: ORIGIN, 'Content-Type': 'application/json' },
          body: JSON.stringify({ username: 'alice', password: 'fixture-password-long' }),
        })
      ).status,
    ).toBe(200)
    const login = await request('/auth/session', {
      method: 'POST',
      headers: { Origin: ORIGIN, 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'alice', password: 'fixture-password-long' }),
    })
    expect(login.status).toBe(200)
    const cookie = (login.headers.get('set-cookie') ?? '').split(';')[0] ?? ''
    expect((await request('/', { headers: { Cookie: cookie } })).status).toBe(200)
    expect((await request('/assets/app.js', { headers: { Cookie: cookie } })).status).toBe(200)
    expect(
      (
        await request('/auth/me', {
          headers: { Origin: ORIGIN, Cookie: cookie },
        })
      ).status,
    ).toBe(200)
    expect(
      (
        await request('/auth/logout', {
          method: 'POST',
          headers: { Origin: ORIGIN, Cookie: cookie },
        })
      ).status,
    ).toBe(200)
    expect((await request('/', { headers: { Cookie: cookie } })).status).toBe(401)
    expect((await request('/auth/unknown', { headers: { Cookie: cookie } })).status).toBe(401)
  })

  it('refuses composition on an already claimed HTTP server', async () => {
    const server = createServer(() => {})
    servers.push(server)
    const sessions = createGatewaySessions()
    const passwordHash = await hashGatewayPassword('fixture-password-long')
    expect(() =>
      attachPrivateGateway(server, {
        publicHost: 'synapse.example.test',
        publicOrigin: ORIGIN,
        sessions,
        accounts: [
          {
            username: 'alice',
            userId: 'alice',
            passwordHash,
          },
        ],
        hosts: new Map(),
        assets: new Map([['/', { content: '<html></html>', contentType: 'text/html' }]]),
      }),
    ).toThrow()
  })
})
