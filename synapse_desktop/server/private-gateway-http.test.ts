import { createServer } from 'node:http'
import { afterEach, describe, expect, it } from 'vitest'
import { createGatewaySessions, sessionCookie } from './gateway-sessions.ts'
import { privateGatewayHttp } from './private-gateway-http.ts'

const servers: ReturnType<typeof createServer>[] = []

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))),
  )
})

describe('private gateway HTTP', () => {
  it('requires a live server-side session without exposing its identity or token', async () => {
    const sessions = createGatewaySessions()
    const server = createServer(privateGatewayHttp(sessions))
    servers.push(server)
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    const address = server.address()
    if (!address || typeof address === 'string') throw new Error('invalid address')
    const url = `http://127.0.0.1:${address.port}/api/session`
    expect((await fetch(url)).status).toBe(401)
    expect((await fetch(url.replace('/api/session', '/'))).status).toBe(404)
    const issued = sessions.issue('alice')
    const cookie = sessionCookie(issued.token).split(';')[0]!
    const authenticated = await fetch(url, { headers: { cookie } })
    expect(authenticated.status).toBe(200)
    expect(await authenticated.json()).toEqual({ authenticated: true })
    sessions.revoke(issued.token)
    expect((await fetch(url, { headers: { cookie } })).status).toBe(401)
  })
})
