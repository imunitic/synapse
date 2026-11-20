import { createServer, type Server } from 'node:http'
import { afterEach, describe, expect, it } from 'vitest'
import { attachProtectedFrontend } from './gateway-protected-frontend.ts'
import { createGatewaySessions, sessionCookie } from './gateway-sessions.ts'

const servers: Server[] = []

async function fixture() {
  const server = createServer()
  servers.push(server)
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('invalid test address')
  const host = `127.0.0.1:${address.port}`
  const sessions = createGatewaySessions()
  attachProtectedFrontend(server, {
    publicHost: host,
    sessions,
    assets: new Map([
      ['/', { content: '<html>Synapse</html>', contentType: 'text/html; charset=utf-8' }],
      ['/assets/main.js', { content: 'console.log("ok")', contentType: 'text/javascript' }],
      ['/manifest.webmanifest', { content: '{}', contentType: 'application/manifest+json' }],
    ]),
  })
  return {
    sessions,
    request: (
      path: string,
      cookie?: string,
      method = 'GET',
      headers: Record<string, string> = {},
    ) =>
      fetch(`http://${host}${path}`, {
        method,
        headers: { ...(cookie ? { Cookie: cookie } : {}), ...headers },
      }),
  }
}

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

describe('protected PWA frontend assets', () => {
  it('refuses unauthenticated page, script, and manifest requests', async () => {
    const f = await fixture()
    expect((await f.request('/')).status).toBe(401)
    expect((await f.request('/assets/main.js')).status).toBe(401)
    expect((await f.request('/manifest.webmanifest')).status).toBe(401)
  })

  it('serves only allowlisted assets to an authenticated browser', async () => {
    const f = await fixture()
    const issued = f.sessions.issue('alice')
    const cookie = sessionCookie(issued.token).split(';')[0]
    const index = await f.request('/', cookie)
    expect(index.status).toBe(200)
    expect(await index.text()).toBe('<html>Synapse</html>')
    expect(index.headers.get('cache-control')).toBe('private, no-store')
    expect(index.headers.get('content-security-policy')).toContain("object-src 'none'")
    expect((await f.request('/assets/main.js', cookie)).status).toBe(200)
    expect((await f.request('/manifest.webmanifest', cookie)).status).toBe(200)
    expect((await f.request('/private-key', cookie)).status).toBe(404)
    expect((await f.request('/auth/unknown', cookie)).status).toBe(404)
    expect((await f.request('/api/unexpected', cookie)).status).toBe(404)
    const head = await f.request('/', cookie, 'HEAD')
    expect(head.status).toBe(200)
    expect(await head.text()).toBe('')
    expect((await f.request('/', cookie, 'POST')).status).toBe(405)
    f.sessions.revoke(issued.token)
    expect((await f.request('/', cookie)).status).toBe(401)
  })

  it('rejects path traversal and encoded path variants', async () => {
    const f = await fixture()
    const issued = f.sessions.issue('alice')
    const cookie = sessionCookie(issued.token).split(';')[0]
    expect((await f.request('/%2e%2e/secret', cookie)).status).toBe(404)
    expect((await f.request('/assets%2fmain.js', cookie)).status).toBe(404)
    expect((await f.request('/assets/main.js?debug=1', cookie)).status).toBe(404)
  })

  it('rejects invalid or reserved manifest entries at attachment time', () => {
    for (const path of ['/../secret', '/auth/session', '/api/secret', '/a%2fb', '//evil']) {
      const server = createServer()
      expect(() =>
        attachProtectedFrontend(server, {
          publicHost: 'synapse.example.test',
          sessions: createGatewaySessions(),
          assets: new Map([
            ['/', { content: 'index', contentType: 'text/html' }],
            [path, { content: 'bad', contentType: 'text/plain' }],
          ]),
        }),
      ).toThrow()
    }
  })
})
