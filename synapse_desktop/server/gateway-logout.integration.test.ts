import { once } from 'node:events'
import { createServer, type Server } from 'node:http'
import { expect, it } from 'vitest'
import { WebSocket, WebSocketServer } from 'ws'
import { BUS_PATH, TOKEN_HEADER } from '../shared/constants.ts'
import { attachPrivateGateway } from './gateway-private-entry.ts'
import { hashGatewayPassword } from './gateway-password-verifier.ts'
import { createGatewaySessions } from './gateway-sessions.ts'

const ORIGIN = 'https://synapse.example.test'
const TOKEN = 'fixture-backend-token'

async function listen(server: Server): Promise<string> {
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('missing fixture address')
  return `127.0.0.1:${address.port}`
}

async function close(server: Server): Promise<void> {
  server.closeAllConnections()
  await new Promise<void>((resolve) => server.close(() => resolve()))
}

it('logout closes the live bus socket and rejects reconnect with the revoked cookie', async () => {
  const backend = createServer()
  const gateway = createServer()
  const wss = new WebSocketServer({ noServer: true })
  const clients: WebSocket[] = []
  backend.on('upgrade', (req, socket, head) => {
    if (
      req.url !== BUS_PATH ||
      req.headers[TOKEN_HEADER] !== TOKEN ||
      req.headers.origin !== 'http://gateway.internal'
    ) {
      socket.destroy()
      return
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req))
  })
  try {
    const backendHost = await listen(backend)
    const host = await listen(gateway)
    attachPrivateGateway(gateway, {
      publicHost: host,
      publicOrigin: ORIGIN,
      sessions: createGatewaySessions(),
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
            backend: `http://${backendHost}`,
            backendOrigin: 'http://gateway.internal',
            backendToken: TOKEN,
          },
        ],
      ]),
      assets: new Map([['/', { content: '<html></html>', contentType: 'text/html' }]]),
    })
    const login = await fetch(`http://${host}/auth/session`, {
      method: 'POST',
      headers: { Origin: ORIGIN, 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'alice', password: 'fixture-password-long' }),
    })
    expect(login.status).toBe(200)
    const cookie = login.headers.get('set-cookie')?.split(';')[0]
    if (!cookie) throw new Error('missing session cookie')
    const connect = () => {
      const ws = new WebSocket(`ws://${host}${BUS_PATH}`, {
        origin: ORIGIN,
        headers: { Cookie: cookie },
      })
      clients.push(ws)
      return ws
    }
    const ws = connect()
    await once(ws, 'open')
    const [logout] = await Promise.all([
      fetch(`http://${host}/auth/logout`, {
        method: 'POST',
        headers: { Origin: ORIGIN, Cookie: cookie },
      }),
      once(ws, 'close', { signal: AbortSignal.timeout(2000) }),
    ])
    expect(logout.status).toBe(200)
    expect(logout.headers.get('set-cookie')).toContain('Max-Age=0')
    const retry = connect()
    const status = await new Promise<number>((resolve, reject) => {
      retry.once('unexpected-response', (_req, response) => {
        response.resume()
        resolve(response.statusCode ?? 0)
      })
      retry.once('open', () => reject(new Error('revoked session reconnected')))
      retry.once('error', reject)
    })
    expect(status).toBe(401)
  } finally {
    for (const ws of clients) if (ws.readyState !== WebSocket.CLOSED) ws.terminate()
    for (const ws of wss.clients) ws.terminate()
    await Promise.all([close(gateway), close(backend)])
    wss.close()
  }
})
