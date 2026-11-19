import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { createServer, type Server } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { WebSocket } from 'ws'
import { BUS_PATH, TOKEN_HEADER } from '../shared/constants.ts'
import { hostMessageSchema, type HostMessage } from '../shared/protocol.ts'
import { attachBus } from './bus.ts'
import { createSessions } from './terminal-sessions.ts'
import { NotStartedHere, RunNotStarted } from './runs.ts'

const TOKEN = 'test-token'
const ORIGIN = 'http://localhost:5173'

let dir: string
let server: Server
let port: number
let sockets: WebSocket[]

beforeEach(async () => {
  sockets = []
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-bus-'))
  await mkdir(join(dir, 'work', 'pipelines'), { recursive: true })
  await writeFile(
    join(dir, 'config.json'),
    JSON.stringify({ workDir: join(dir, 'work'), definitionPaths: [], defaultHarness: null }),
  )
  await writeFile(join(dir, 'work', 'pipelines', 'a.json'), '{"a":1}')
  const hosts = new Set<string>()
  server = createServer()
  attachBus(server, {
    sessions: createSessions({
      environment: { env: {}, home: dir },
      configFile: join(dir, 'config.json'),
      spawn: () => {
        throw new Error('no terminals here')
      },
      plan: () => Promise.reject(new Error('no terminals here')),
      maxTerminals: 1,
      sessionsRoot: join(dir, 'sessions'),
      loginEnvironment: () => Promise.resolve(null),
    }),
    policy: { allowedHosts: hosts, allowedOrigins: new Set([ORIGIN]), token: TOKEN },
    context: {
      environment: { env: { XDG_CONFIG_HOME: join(dir, 'xdg') }, home: dir },
      configFile: join(dir, 'config.json'),
      runs: {
        start: () => Promise.reject(new RunNotStarted('stub')),
        stop: () => {
          throw new NotStartedHere('stub')
        },
      },
      agent: () => Promise.reject(new Error('not used')),
      noteSession: () => Promise.reject(new Error('not used')),
      runCli: () => Promise.resolve({ code: 0, stdout: 'ok', stderr: '' }),
    },
    report: () => undefined,
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  port = address.port
  hosts.add(`127.0.0.1:${port}`)
})

afterEach(async () => {
  for (const socket of sockets) socket.terminate()
  server.closeAllConnections()
  await new Promise((resolve) => server.close(resolve))
  await rm(dir, { recursive: true, force: true })
})

interface Open {
  socket: WebSocket
  next: () => Promise<HostMessage>
}

// Connects with these headers; resolves to the socket, with what it receives collected from the
// first byte, or to the status that refused it.
function connect(headers: Record<string, string>, path = BUS_PATH) {
  return new Promise<Open | { refused: number }>((resolve) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}${path}`, { headers })
    sockets.push(socket)
    const queue: HostMessage[] = []
    const waiting: ((m: HostMessage) => void)[] = []
    socket.on('message', (data) => {
      const message = hostMessageSchema.parse(JSON.parse(String(data)))
      const wait = waiting.shift()
      if (wait === undefined) queue.push(message)
      else wait(message)
    })
    const next = () =>
      new Promise<HostMessage>((done) => {
        const ready = queue.shift()
        if (ready === undefined) waiting.push(done)
        else done(ready)
      })
    socket.on('open', () => resolve({ socket, next }))
    socket.on('unexpected-response', (_req, res) => resolve({ refused: res.statusCode ?? 0 }))
    socket.on('error', () => resolve({ refused: 0 }))
  })
}

const good = { origin: ORIGIN, [TOKEN_HEADER]: TOKEN }

async function open(): Promise<Open> {
  const connected = await connect(good)
  if (!('socket' in connected)) throw new Error('refused')
  return connected
}

describe('the bus of the Node host', () => {
  it('says what it can do first, when the handshake passes', async () => {
    const { socket, next } = await open()
    const hello = await next()
    expect(hello).toMatchObject({ kind: 'hello', protocol: 1, capabilities: { host: 'node' } })
    socket.close()
  })

  it('refuses a handshake with no token, a wrong token, a foreign origin or a foreign host', async () => {
    expect(await connect({ origin: ORIGIN })).toEqual({ refused: 401 })
    expect(await connect({ origin: ORIGIN, [TOKEN_HEADER]: 'wrong' })).toEqual({ refused: 401 })
    expect(await connect({ origin: 'http://evil.example', [TOKEN_HEADER]: TOKEN })).toEqual({
      refused: 403,
    })
    expect(await connect({ ...good, host: 'evil.example' })).toEqual({ refused: 403 })
  })

  it('answers a request with its result', async () => {
    const { socket, next } = await open()
    await next()
    socket.send(
      JSON.stringify({
        kind: 'request',
        id: 'r1',
        name: 'fs.read',
        params: { path: join(dir, 'work', 'pipelines', 'a.json') },
      }),
    )
    expect(await next()).toEqual({ kind: 'reply', id: 'r1', result: { text: '{"a":1}' } })
    socket.close()
  })

  it('gives a refusal of a handler its code', async () => {
    const { socket, next } = await open()
    await next()
    socket.send(
      JSON.stringify({
        kind: 'request',
        id: 'r1',
        name: 'fs.read',
        params: { path: '/etc/passwd' },
      }),
    )
    expect(await next()).toMatchObject({ kind: 'reply', id: 'r1', error: { code: 'forbidden' } })
    socket.send(JSON.stringify({ kind: 'request', id: 'r2', name: 'nothing.at.all', params: {} }))
    expect(await next()).toMatchObject({ id: 'r2', error: { code: 'not_found' } })
    socket.send(JSON.stringify({ kind: 'request', id: 'r3', name: 'fs.read', params: { path: 1 } }))
    expect(await next()).toMatchObject({ id: 'r3', error: { code: 'bad_request' } })
    socket.close()
  })

  it('reads the settings and the paths in one answer', async () => {
    const { socket, next } = await open()
    await next()
    socket.send(JSON.stringify({ kind: 'request', id: 'r1', name: 'config.get', params: {} }))
    const reply = await next()
    expect(reply).toMatchObject({
      id: 'r1',
      result: { config: { workDir: join(dir, 'work') }, paths: { recordsDir: expect.any(String) } },
    })
    socket.close()
  })

  it('ignores a message that is not JSON and goes on answering', async () => {
    const { socket, next } = await open()
    await next()
    socket.send('not json')
    socket.send(JSON.stringify({ kind: 'request', id: 'r1', name: 'integrations', params: {} }))
    expect(await next()).toMatchObject({ kind: 'reply', id: 'r1' })
    socket.close()
  })
})
