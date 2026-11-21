import { createServer, type Server } from 'node:http'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { attachGatewayHttpAuth } from './gateway-http-auth.ts'
import { createGatewaySessions } from './gateway-sessions.ts'
import { VERIFIER_BUSY } from './gateway-password-verifier.ts'

const ORIGIN = 'https://synapse.example.test'
const openServers: Server[] = []

async function fixture(maxAttempts = 5) {
  const server = createServer()
  openServers.push(server)
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('invalid listen address')
  const host = `127.0.0.1:${address.port}`
  const sessions = createGatewaySessions()
  let checks = 0
  attachGatewayHttpAuth(server, {
    publicHost: host,
    publicOrigin: ORIGIN,
    sessions,
    maxAttempts,
    verifyCredentials: async (username, password) => {
      checks += 1
      return username === 'alice' && password === 'fixture-password' ? 'alice' : null
    },
  })
  return {
    sessions,
    checks: () => checks,
    request: (
      path: string,
      method = 'GET',
      body?: string,
      cookie?: string,
      origin: string | null = ORIGIN,
    ) =>
      fetch(`http://${host}${path}`, {
        method,
        headers: {
          ...(origin === null ? {} : { Origin: origin }),
          ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
          ...(cookie === undefined ? {} : { Cookie: cookie }),
        },
        body,
      }),
  }
}

afterEach(async () => {
  await Promise.all(
    openServers.splice(0).map(
      (server) =>
        new Promise<void>((resolve) => {
          server.closeAllConnections()
          server.close(() => resolve())
        }),
    ),
  )
})

describe('private gateway HTTP authentication', () => {
  it('issues an opaque, secure cookie only after trusted verification', async () => {
    const f = await fixture()
    const invalid = await f.request(
      '/auth/session',
      'POST',
      JSON.stringify({ username: 'alice', password: 'bad' }),
    )
    expect(invalid.status).toBe(401)
    expect(invalid.headers.get('set-cookie')).toBeNull()

    const good = await f.request(
      '/auth/session',
      'POST',
      JSON.stringify({ username: 'alice', password: 'fixture-password' }),
    )
    expect(good.status).toBe(200)
    const cookie = good.headers.get('set-cookie') ?? ''
    expect(cookie).toContain('HttpOnly; Secure; SameSite=Strict')
    const tokenCookie = cookie.split(';')[0]
    expect(tokenCookie).toMatch(/^synapse_session=[A-Za-z0-9_-]{43}$/)
    expect(cookie).not.toContain('fixture-password')
    expect((await f.request('/auth/me', 'GET', undefined, tokenCookie)).status).toBe(200)
    expect(f.checks()).toBe(2)
  })

  it('revokes on logout, clears cookie and denies session reuse', async () => {
    const f = await fixture()
    const login = await f.request(
      '/auth/session',
      'POST',
      JSON.stringify({ username: 'alice', password: 'fixture-password' }),
    )
    const cookie = (login.headers.get('set-cookie') ?? '').split(';')[0]
    expect((await f.request('/auth/me', 'GET', undefined, cookie)).status).toBe(200)
    const logout = await f.request('/auth/logout', 'POST', undefined, cookie)
    expect(logout.status).toBe(200)
    expect(logout.headers.get('set-cookie')).toContain('Max-Age=0')
    expect((await f.request('/auth/me', 'GET', undefined, cookie)).status).toBe(401)
  })

  it('refuses cross-origin requests and disallowed methods', async () => {
    const f = await fixture()
    const credentials = JSON.stringify({ username: 'alice', password: 'fixture-password' })
    expect(
      (await f.request('/auth/session', 'POST', credentials, undefined, 'https://attacker.example'))
        .status,
    ).toBe(403)
    expect(
      (await f.request('/auth/logout', 'POST', undefined, undefined, 'https://attacker.example'))
        .status,
    ).toBe(403)
    expect((await f.request('/auth/session', 'GET')).status).toBe(405)
    expect((await f.request('/auth/logout', 'GET')).status).toBe(405)
    expect((await f.request('/auth/me', 'POST')).status).toBe(405)
    expect(f.checks()).toBe(0)
  })

  it('accepts same-origin browser GET without Origin but rejects a foreign Origin', async () => {
    const f = await fixture()
    const issued = f.sessions.issue('alice')
    const cookie = `synapse_session=${issued.token}`
    expect((await f.request('/auth/me', 'GET', undefined, cookie, null)).status).toBe(200)
    expect(
      (await f.request('/auth/me', 'GET', undefined, cookie, 'https://attacker.example')).status,
    ).toBe(403)
  })

  it('reports password verifier saturation as busy rather than bad credentials', async () => {
    const server = createServer()
    openServers.push(server)
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    const address = server.address()
    if (!address || typeof address === 'string') throw new Error('invalid address')
    const host = `127.0.0.1:${address.port}`
    attachGatewayHttpAuth(server, {
      publicHost: host,
      publicOrigin: ORIGIN,
      sessions: createGatewaySessions(),
      verifyCredentials: async () => VERIFIER_BUSY,
    })
    const response = await fetch(`http://${host}/auth/session`, {
      method: 'POST',
      headers: { Origin: ORIGIN, 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify({ username: 'alice', password: 'some-password' }),
    })
    expect(response.status).toBe(503)
    expect(await response.json()).toEqual({ error: 'service_busy' })
  })

  it('reports a missing trusted client identity as a server fault, not rate limiting', async () => {
    const server = createServer()
    openServers.push(server)
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    const address = server.address()
    if (!address || typeof address === 'string') throw new Error('invalid address')
    const host = `127.0.0.1:${address.port}`
    let verified = false
    attachGatewayHttpAuth(server, {
      publicHost: host,
      publicOrigin: ORIGIN,
      sessions: createGatewaySessions(),
      peerKey: () => null,
      verifyCredentials: async () => {
        verified = true
        return 'alice'
      },
    })
    const errorLog = vi.spyOn(console, 'error').mockImplementation(() => {})
    try {
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const response = await fetch(`http://${host}/auth/session`, {
          method: 'POST',
          headers: { Origin: ORIGIN, 'Content-Type': 'application/json' },
          body: JSON.stringify({ username: 'alice', password: 'some-password' }),
        })
        expect(response.status).toBe(503)
        expect(await response.json()).toEqual({ error: 'service_unavailable' })
      }
      expect(errorLog).toHaveBeenCalledTimes(1)
      expect(verified).toBe(false)
    } finally {
      errorLog.mockRestore()
    }
  })

  it('limits login attempts and never invokes verifier once rate limited', async () => {
    const f = await fixture(2)
    const body = JSON.stringify({ username: 'alice', password: 'wrong' })
    expect((await f.request('/auth/session', 'POST', body)).status).toBe(401)
    expect((await f.request('/auth/session', 'POST', body)).status).toBe(401)
    expect((await f.request('/auth/session', 'POST', body)).status).toBe(429)
    expect(f.checks()).toBe(2)
  })

  it('rejects malformed payloads and an unauthenticated status check', async () => {
    const f = await fixture()
    expect((await f.request('/auth/me')).status).toBe(401)
    expect((await f.request('/auth/session', 'POST', '{}')).status).toBe(400)
    expect((await f.request('/auth/session', 'POST', 'not-json')).status).toBe(400)
    expect(f.checks()).toBe(0)
  })
})
