import { createServer, type Server } from 'node:http'
import { afterEach, describe, expect, it } from 'vitest'
import { WebSocket, WebSocketServer } from 'ws'
import { BUS_PATH, TOKEN_HEADER } from '../shared/constants.ts'
import { attachPrivateGateway } from './gateway-private-entry.ts'
import { hashGatewayPassword } from './gateway-password-verifier.ts'
import { attachSessionGateway } from './gateway-session-adapter.ts'
import { createGatewaySessions, sessionCookie } from './gateway-sessions.ts'

const ORIGIN = 'https://synapse.example.test'
const INTERNAL_ORIGIN = 'http://gateway.internal'
const TOKEN = 'private-host-token'

const openServers: Server[] = []
const openSockets: WebSocket[] = []

async function listen(server: Server): Promise<number> {
  openServers.push(server)
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('invalid server')
  return address.port
}

function connect(port: number, cookie?: string): Promise<WebSocket | number> {
  return new Promise((resolve) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}${BUS_PATH}`, {
      origin: ORIGIN,
      headers: cookie === undefined ? {} : { cookie },
    })
    openSockets.push(socket)
    socket.once('open', () => resolve(socket))
    socket.once('unexpected-response', (_request, response) => resolve(response.statusCode ?? 0))
    socket.once('error', () => resolve(0))
  })
}

afterEach(async () => {
  for (const socket of openSockets.splice(0)) socket.terminate()
  await Promise.all(
    openServers
      .splice(0)
      .map((server) => new Promise<void>((resolve) => server.close(() => resolve()))),
  )
})

describe('gateway session integration', () => {
  it('uses the real session store to admit and revoke an existing WebSocket', async () => {
    const sessions = createGatewaySessions()
    const issued = sessions.issue('alice')

    const backend = createServer()
    const backendSockets = new WebSocketServer({ noServer: true })
    backend.on('upgrade', (request, socket, head) => {
      if (
        request.url !== BUS_PATH ||
        request.headers[TOKEN_HEADER] !== TOKEN ||
        request.headers.origin !== INTERNAL_ORIGIN
      ) {
        socket.destroy()
        return
      }
      backendSockets.handleUpgrade(request, socket, head, (ws) => {
        openSockets.push(ws)
        ws.on('message', (data) => ws.send(String(data)))
      })
    })
    const backendPort = await listen(backend)

    const gateway = createServer()
    const gatewayPort = await listen(gateway)
    attachSessionGateway(gateway, {
      publicHost: `127.0.0.1:${gatewayPort}`,
      publicOrigin: ORIGIN,
      hosts: new Map([
        [
          'alice',
          {
            userId: 'alice',
            backend: `http://127.0.0.1:${backendPort}`,
            backendToken: TOKEN,
            backendOrigin: INTERNAL_ORIGIN,
          },
        ],
      ]),
      sessions,
      recheckMs: 20,
    })

    expect(await connect(gatewayPort)).toBe(401)
    const connected = await connect(gatewayPort, sessionCookie(issued.token).split(';')[0])
    if (typeof connected === 'number') throw new Error('valid session refused')

    const echoed = new Promise<string>((resolve) => {
      connected.once('message', (data) => resolve(String(data)))
    })
    connected.send(JSON.stringify({ kind: 'request', id: 'test' }))
    expect(await echoed).toBe(JSON.stringify({ kind: 'request', id: 'test' }))

    // A browser reload closes the old socket; the same authenticated session
    // must be able to reconnect to its original private backend.
    const disconnected = new Promise<void>((resolve) => connected.once('close', () => resolve()))
    connected.close()
    await disconnected
    const reconnected = await connect(gatewayPort, sessionCookie(issued.token).split(';')[0])
    if (typeof reconnected === 'number') throw new Error('valid reconnect refused')
    const afterReload = new Promise<string>((resolve) => {
      reconnected.once('message', (data) => resolve(String(data)))
    })
    const reloadMessage = JSON.stringify({ kind: 'request', id: 'after-reload' })
    reconnected.send(reloadMessage)
    expect(await afterReload).toBe(reloadMessage)

    const closed = new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('revoked session stayed connected')), 1000)
      reconnected.once('close', () => {
        clearTimeout(timeout)
        resolve()
      })
    })
    sessions.revoke(issued.token)
    await closed
    expect(await connect(gatewayPort, sessionCookie(issued.token).split(';')[0])).toBe(401)
  })
  it('disconnects only the logged-out session before the periodic recheck', async () => {
    const sessions = createGatewaySessions()
    const first = sessions.issue('alice')
    const second = sessions.issue('alice')
    const backend = createServer()
    const sockets = new WebSocketServer({ noServer: true })
    backend.on('upgrade', (request, socket, head) => {
      if (request.headers[TOKEN_HEADER] !== TOKEN) {
        socket.destroy()
        return
      }
      sockets.handleUpgrade(request, socket, head, (ws) => {
        openSockets.push(ws)
        ws.on('message', (data) => ws.send(String(data)))
      })
    })
    const backendPort = await listen(backend)
    const gateway = createServer()
    const port = await listen(gateway)
    const host = `127.0.0.1:${port}`
    attachPrivateGateway(gateway, {
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
      hosts: new Map([
        [
          'alice',
          {
            userId: 'alice',
            backend: `http://127.0.0.1:${backendPort}`,
            backendToken: TOKEN,
            backendOrigin: INTERNAL_ORIGIN,
          },
        ],
      ]),
      assets: new Map([['/', { content: 'fixture', contentType: 'text/html' }]]),
      recheckMs: 60_000,
    })
    const firstCookie = sessionCookie(first.token).split(';')[0]
    const secondCookie = sessionCookie(second.token).split(';')[0]
    const a = await connect(port, firstCookie)
    const b = await connect(port, secondCookie)
    if (typeof a === 'number' || typeof b === 'number') throw new Error('session refused')
    const closed = new Promise<void>((resolve) => a.once('close', () => resolve()))
    const response = await fetch(`http://${host}/auth/logout`, {
      method: 'POST',
      headers: { Origin: ORIGIN, Cookie: firstCookie ?? '' },
    })
    expect(response.status).toBe(200)
    await closed
    expect(await connect(port, firstCookie)).toBe(401)
    const echoed = new Promise<string>((resolve) => {
      b.once('message', (data) => resolve(String(data)))
    })
    b.send('still-connected')
    expect(await echoed).toBe('still-connected')
  })

  it('routes two authenticated users to separate private buses and denies cross-user cookies', async () => {
    const sessions = createGatewaySessions()
    const alice = sessions.issue('alice')
    const bob = sessions.issue('bob')
    const received = new Map<string, string[]>()
    const hosts = new Map<
      string,
      { userId: string; backend: string; backendToken: string; backendOrigin: string }
    >()

    for (const userId of ['alice', 'bob']) {
      const backend = createServer()
      const sockets = new WebSocketServer({ noServer: true })
      received.set(userId, [])
      backend.on('upgrade', (request, socket, head) => {
        if (
          request.url !== BUS_PATH ||
          request.headers[TOKEN_HEADER] !== TOKEN ||
          request.headers.origin !== INTERNAL_ORIGIN
        ) {
          socket.destroy()
          return
        }
        sockets.handleUpgrade(request, socket, head, (ws) => {
          openSockets.push(ws)
          ws.on('message', (data) => {
            received.get(userId)?.push(String(data))
            ws.send(userId)
          })
        })
      })
      const port = await listen(backend)
      hosts.set(userId, {
        userId,
        backend: `http://127.0.0.1:${port}`,
        backendToken: TOKEN,
        backendOrigin: INTERNAL_ORIGIN,
      })
    }

    const gateway = createServer()
    const gatewayPort = await listen(gateway)
    attachSessionGateway(gateway, {
      publicHost: `127.0.0.1:${gatewayPort}`,
      publicOrigin: ORIGIN,
      hosts,
      sessions,
      recheckMs: 20,
    })

    const users = [
      [alice, 'alice'],
      [bob, 'bob'],
    ] as const
    for (const [issued, expected] of users) {
      const socket = await connect(gatewayPort, sessionCookie(issued.token).split(';')[0])
      if (typeof socket === 'number') throw new Error(`${expected} connection refused`)
      const reply = new Promise<string>((resolve) =>
        socket.once('message', (data) => resolve(String(data))),
      )
      socket.send(`from-${expected}`)
      expect(await reply).toBe(expected)
    }
    expect(received.get('alice')).toEqual(['from-alice'])
    expect(received.get('bob')).toEqual(['from-bob'])
    expect(await connect(gatewayPort, 'synapse_session=invalid')).toBe(401)
  })
})
