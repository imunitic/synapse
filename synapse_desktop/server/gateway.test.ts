import { createServer, type Server } from 'node:http'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { WebSocket, WebSocketServer } from 'ws'
import { BUS_PATH, TOKEN_HEADER } from '../shared/constants.ts'
import { attachGateway, type GatewayHost, type GatewaySession } from './gateway.ts'

const ORIGIN = 'https://synapse.example.test'
const TOKEN_A = 'private-token-a'
const TOKEN_B = 'private-token-b'

let gateway: Server
let backendA: Server
let backendB: Server
let gatewayPort: number
let aCount: number
let bCount: number
let aHeaders: Record<string, string | string[] | undefined>
let bHeaders: Record<string, string | string[] | undefined>
let revoked: Set<string>
let clients: WebSocket[]
let upstreams: WebSocket[]

async function listen(server: Server): Promise<number> {
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no server port')
  return address.port
}

function privateBackend(
  name: string,
  token: string,
  increment: (headers: typeof aHeaders) => void,
): Server {
  const server = createServer((_req, res) => {
    res.writeHead(404).end()
  })
  const sockets = new WebSocketServer({ noServer: true })
  server.on('upgrade', (req, socket, head) => {
    if (
      req.url !== BUS_PATH ||
      req.headers[TOKEN_HEADER] !== token ||
      req.headers.origin !== 'http://gateway.internal'
    ) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n')
      socket.destroy()
      return
    }
    increment(req.headers)
    sockets.handleUpgrade(req, socket, head, (ws) => {
      upstreams.push(ws)
      ws.send(JSON.stringify({ kind: 'hello', from: name }))
      ws.on('message', (data) => ws.send(data.toString()))
    })
  })
  return server
}

interface Connected {
  socket: WebSocket
  next: () => Promise<unknown>
}

function connect(
  cookie?: string,
  headers: Record<string, string> = {},
  origin = ORIGIN,
): Promise<Connected | { refused: number; retryAfter?: string }> {
  return new Promise((resolve) => {
    const socket = new WebSocket(`ws://127.0.0.1:${gatewayPort}${BUS_PATH}`, {
      origin,
      headers: { ...(cookie ? { cookie } : {}), ...headers },
    })
    clients.push(socket)
    const queued: unknown[] = []
    const waiting: Array<(value: unknown) => void> = []
    socket.on('message', (data) => {
      const value: unknown = JSON.parse(String(data))
      const listener = waiting.shift()
      if (listener === undefined) queued.push(value)
      else listener(value)
    })
    const next = (): Promise<unknown> =>
      new Promise((done) => {
        const value = queued.shift()
        if (value === undefined) waiting.push(done)
        else done(value)
      })
    socket.once('open', () => resolve({ socket, next }))
    socket.once('unexpected-response', (_request, response) => {
      const refused = response.statusCode ?? 0
      resolve(
        refused === 429 ? { refused, retryAfter: response.headers['retry-after'] } : { refused },
      )
    })
    socket.once('error', () => resolve({ refused: 0 }))
  })
}

beforeEach(async () => {
  clients = []
  upstreams = []
  aCount = 0
  bCount = 0
  aHeaders = {}
  bHeaders = {}
  revoked = new Set()
  backendA = privateBackend('a', TOKEN_A, (headers) => {
    aCount++
    aHeaders = headers
  })
  backendB = privateBackend('b', TOKEN_B, (headers) => {
    bCount++
    bHeaders = headers
  })
  const aPort = await listen(backendA)
  const bPort = await listen(backendB)
  gateway = createServer((_req, res) => res.writeHead(404).end())
  gatewayPort = await listen(gateway)
  const hosts = new Map<string, GatewayHost>([
    [
      'a',
      {
        userId: 'a',
        backend: `http://127.0.0.1:${aPort}`,
        backendOrigin: 'http://gateway.internal',
        backendToken: TOKEN_A,
      },
    ],
    [
      'b',
      {
        userId: 'b',
        backend: `http://127.0.0.1:${bPort}`,
        backendOrigin: 'http://gateway.internal',
        backendToken: TOKEN_B,
      },
    ],
  ])
  attachGateway(gateway, {
    publicHost: `127.0.0.1:${gatewayPort}`,
    publicOrigin: ORIGIN,
    hosts,
    recheckMs: 20,
    authenticate: async (request): Promise<GatewaySession | null> => {
      // This is a test-only session store stub, not production login logic.
      const match = /(?:^|;\s*)sid=(a|b)(?:;|$)/.exec(request.headers.cookie ?? '')
      const userId = match?.[1]
      const instance = /(?:^|;\s*)instance=([0-9]+)(?:;|$)/.exec(request.headers.cookie ?? '')?.[1]
      return userId ? { userId, sessionId: instance ? `${userId}-${instance}` : userId } : null
    },
    sessionValid: async (session) => !revoked.has(session.sessionId),
  })
})

afterEach(async () => {
  for (const socket of [...clients, ...upstreams]) socket.terminate()
  await Promise.all(
    [gateway, backendA, backendB].map(
      (server) => new Promise<void>((resolve) => server.close(() => resolve())),
    ),
  )
})

describe('private Synapse WebSocket gateway', () => {
  it('routes an authenticated user to their own host and preserves the Synapse message payload', async () => {
    const result = await connect('sid=a', { 'x-user-id': 'b', [TOKEN_HEADER]: TOKEN_B })
    if (!('socket' in result)) throw new Error('gateway refused the authenticated session')
    const { socket } = result
    expect(await result.next()).toEqual({ kind: 'hello', from: 'a' })
    const reply = result.next()
    socket.send(JSON.stringify({ kind: 'request', id: 'one', params: {} }))
    expect(await reply).toEqual({ kind: 'request', id: 'one', params: {} })
    expect(aCount).toBe(1)
    expect(bCount).toBe(0)
    expect(aHeaders.cookie).toBeUndefined()
    expect(aHeaders['x-user-id']).toBeUndefined()
    expect(aHeaders[TOKEN_HEADER]).toBe(TOKEN_A)
  })

  it('routes the other user to their own backend', async () => {
    const result = await connect('sid=b')
    if (!('socket' in result)) throw new Error('gateway refused the authenticated session')
    expect(await result.next()).toEqual({ kind: 'hello', from: 'b' })
    expect(aCount).toBe(0)
    expect(bCount).toBe(1)
    expect(bHeaders[TOKEN_HEADER]).toBe(TOKEN_B)
  })

  it('refuses unauthenticated and forged-identity requests without contacting a host', async () => {
    expect(await connect(undefined, { 'x-user-id': 'a' })).toEqual({ refused: 401 })
    expect(await connect('sid=invalid')).toEqual({ refused: 401 })
    expect(aCount).toBe(0)
    expect(bCount).toBe(0)
  })

  it('refuses a foreign browser Origin before authenticating', async () => {
    expect(await connect('sid=a', {}, 'https://attacker.example')).toEqual({ refused: 403 })
    expect(aCount).toBe(0)
    expect(bCount).toBe(0)
  })

  it('rejects a forged public Host even with a valid session', async () => {
    expect(await connect('sid=a', { host: 'untrusted.example' })).toEqual({ refused: 403 })
    expect(aCount).toBe(0)
    expect(bCount).toBe(0)
  })

  it('cannot connect directly to the private backend without its gateway credential', async () => {
    const aPort = (backendA.address() as { port: number }).port
    const result = await new Promise<number>((resolve) => {
      const socket = new WebSocket(`ws://127.0.0.1:${aPort}${BUS_PATH}`, { origin: ORIGIN })
      clients.push(socket)
      socket.once('unexpected-response', (_request, response) => resolve(response.statusCode ?? 0))
      socket.once('error', () => resolve(0))
    })
    expect(result).toBe(401)
    expect(aCount).toBe(0)
  })

  it('reserves reconnect headroom and returns retry advice at the per-user cap', async () => {
    const first = await connect('sid=a; instance=1')
    const second = await connect('sid=a; instance=2')
    const third = await connect('sid=a; instance=3')
    const fourth = await connect('sid=a; instance=4')
    for (const result of [first, second, third, fourth]) {
      if (!('socket' in result)) throw new Error('expected initial connections')
      expect(await result.next()).toEqual({ kind: 'hello', from: 'a' })
    }
    expect(await connect('sid=a; instance=5')).toEqual({ refused: 429, retryAfter: '5' })
    const other = await connect('sid=b')
    if (!('socket' in other)) throw new Error('other user incorrectly blocked')
    expect(await other.next()).toEqual({ kind: 'hello', from: 'b' })
    // Closed connections must free the slot for a legitimate reconnect.
    if (!('socket' in first)) throw new Error('expected open first connection')
    first.socket.terminate()
    await new Promise<void>((resolve) => first.socket.once('close', resolve))
    // Give the gateway a bounded chance to observe the TCP close rather
    // than relying on a fixed wall-clock sleep on slower CI runners.
    const deadline = Date.now() + 1500
    let reconnect = await connect('sid=a; instance=6')
    while (!('socket' in reconnect) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 25))
      reconnect = await connect('sid=a; instance=6')
    }
    if (!('socket' in reconnect)) throw new Error('reconnect did not reclaim freed slot')
    expect(await reconnect.next()).toEqual({ kind: 'hello', from: 'a' })
  })

  it('replaces only a previous socket from the same login session at capacity', async () => {
    const first = await connect('sid=a; instance=1')
    const second = await connect('sid=a; instance=2')
    const third = await connect('sid=a; instance=3')
    const fourth = await connect('sid=a; instance=4')
    for (const result of [first, second, third, fourth]) {
      if (!('socket' in result)) throw new Error('initial connection refused')
      await result.next()
    }
    if (!('socket' in first) || !('socket' in second)) {
      throw new Error('missing initial WebSocket')
    }
    const firstClosed = new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('old session socket remained open')), 1500)
      first.socket.once('close', () => {
        clearTimeout(timeout)
        resolve()
      })
    })
    const replacement = await connect('sid=a; instance=1')
    if (!('socket' in replacement)) throw new Error('same-session reconnect was refused')
    expect(await replacement.next()).toEqual({ kind: 'hello', from: 'a' })
    await firstClosed
    expect(second.socket.readyState).toBe(WebSocket.OPEN)
    expect(await connect('sid=a; instance=5')).toEqual({ refused: 429, retryAfter: '5' })
  })

  it('closes an existing WebSocket when its server-side session is revoked', async () => {
    const result = await connect('sid=a')
    if (!('socket' in result)) throw new Error('gateway refused the authenticated session')
    await result.next()
    const closed = new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('revoked socket remained open')), 1000)
      result.socket.once('close', () => {
        clearTimeout(timeout)
        resolve()
      })
    })
    revoked.add('a')
    await closed
  })
})
