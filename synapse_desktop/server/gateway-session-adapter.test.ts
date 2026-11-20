import { createServer, type Server } from 'node:http'
import { afterEach, describe, expect, it } from 'vitest'
import { WebSocket, WebSocketServer } from 'ws'
import { BUS_PATH, TOKEN_HEADER } from '../shared/constants.ts'
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

    const closed = new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('revoked session stayed connected')), 1000)
      connected.once('close', () => {
        clearTimeout(timeout)
        resolve()
      })
    })
    sessions.revoke(issued.token)
    await closed
    expect(await connect(gatewayPort, sessionCookie(issued.token).split(';')[0])).toBe(401)
  })
})
