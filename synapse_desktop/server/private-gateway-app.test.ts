import { createServer, type Server } from 'node:http'
import { afterEach, describe, expect, it } from 'vitest'
import { WebSocket } from 'ws'
import { BUS_PATH } from '../shared/constants.ts'
import { createPrivateGatewayApp } from './private-gateway-app.ts'
import { createGatewaySessions, sessionCookie } from './gateway-sessions.ts'

const servers: Server[] = []
const sockets: WebSocket[] = []

afterEach(async () => {
  for (const socket of sockets.splice(0)) socket.terminate()
  await Promise.all(
    servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))),
  )
})

describe('private gateway composition', () => {
  it('shares the session store between HTTP and WebSocket authorization', async () => {
    const sessions = createGatewaySessions()
    const issued = sessions.issue('alice')
    const gateway = createPrivateGatewayApp({
      publicHost: '127.0.0.1:0',
      publicOrigin: 'https://synapse.example.test',
      hosts: new Map(),
      sessions,
    })
    servers.push(gateway)
    await new Promise<void>((resolve) => gateway.listen(0, '127.0.0.1', resolve))
    const address = gateway.address()
    if (!address || typeof address === 'string') throw new Error('invalid address')
    const port = address.port
    const cookie = sessionCookie(issued.token).split(';')[0]
    const url = `http://127.0.0.1:${port}/api/session`
    expect((await fetch(url)).status).toBe(401)
    expect((await fetch(url, { headers: { cookie } })).status).toBe(200)
    const denied = await new Promise<number>((resolve) => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}${BUS_PATH}`, {
        origin: 'https://synapse.example.test',
      })
      sockets.push(socket)
      socket.once('unexpected-response', (_request, response) => resolve(response.statusCode ?? 0))
      socket.once('error', () => resolve(0))
    })
    expect(denied).toBe(403)
    sessions.revoke(issued.token)
    expect((await fetch(url, { headers: { cookie } })).status).toBe(401)
  })
})
