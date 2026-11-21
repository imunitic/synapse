// Real Synapse Node bus behind the detached authenticated gateway.
// Only the operating-system PTY is replaced with an in-memory fake.
// No remote host mode, public listener, real shell or agent is started.
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { createServer, type Server } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { WebSocket } from 'ws'
import { BUS_PATH } from '../shared/constants.ts'
import { attachBus } from './bus.ts'
import { attachPrivateGateway } from './gateway-private-entry.ts'
import { hashGatewayPassword } from './gateway-password-verifier.ts'
import { createGatewaySessions, sessionCookie } from './gateway-sessions.ts'
import { createSessions } from './terminal-sessions.ts'

const ORIGIN = 'https://synapse.example.test'
const BACKEND_ORIGIN = 'http://gateway.internal'
const TOKEN = 'gateway-owned-integration-token'
const servers: Server[] = []
const clients: WebSocket[] = []
const directories: string[] = []

async function listen(server: Server): Promise<number> {
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('invalid test socket')
  servers.push(server)
  return address.port
}

afterEach(async () => {
  for (const socket of clients) socket.terminate()
  clients.length = 0
  for (const server of servers.splice(0).reverse()) {
    server.closeAllConnections()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  }
  await Promise.all(directories.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe('authenticated gateway to real Node bus', () => {
  it('starts a terminal, echoes input, and lists it using real bus handlers', async () => {
    const home = await mkdtemp(join(tmpdir(), 'synapse-gateway-bus-'))
    directories.push(home)
    const work = join(home, 'work')
    await mkdir(work)
    const configFile = join(home, 'config.json')
    await writeFile(
      configFile,
      JSON.stringify({ workDir: work, definitionPaths: [], defaultHarness: null }),
    )
    let output: ((text: string) => void) | undefined
    let killed = false
    const sessions = createSessions({
      environment: { env: {}, home },
      configFile,
      sessionsRoot: join(home, 'sessions'),
      maxTerminals: 2,
      plan: async () => ({ command: 'fake-shell', args: [], env: {}, loaded: false, note: '' }),
      spawn: () => ({
        onData: (listener) => {
          output = listener
        },
        onExit: () => undefined,
        write: (data) => output?.(data),
        resize: () => undefined,
        kill: () => {
          killed = true
        },
      }),
      watch: () => ({
        stop: () => undefined,
        poll: async () => undefined,
        register: () => undefined,
      }),
    })
    const backend = createServer((_req, res) => res.writeHead(404).end())
    const allowedHosts = new Set<string>()
    attachBus(backend, {
      policy: {
        allowedHosts,
        allowedOrigins: new Set([BACKEND_ORIGIN]),
        token: TOKEN,
      },
      sessions,
      context: {
        environment: { env: { XDG_CONFIG_HOME: join(home, 'xdg') }, home },
        configFile,
        runCli: async () => ({ code: 0, stdout: '', stderr: '' }),
        runs: {
          start: async () => {
            throw new Error('agent execution disabled in gateway integration test')
          },
          stop: () => {
            throw new Error('agent execution disabled in gateway integration test')
          },
        },
        agent: async () => {
          throw new Error('agent execution disabled in gateway integration test')
        },
        noteSession: async () => {
          throw new Error('agent execution disabled in gateway integration test')
        },
      },
      report: () => undefined,
    })
    const backendPort = await listen(backend)
    allowedHosts.add(`127.0.0.1:${backendPort}`)

    const gateway = createServer()
    const gatewayPort = await listen(gateway)
    const gatewayHost = `127.0.0.1:${gatewayPort}`
    const auth = createGatewaySessions()
    const issued = auth.issue('fixture-user')
    attachPrivateGateway(gateway, {
      publicHost: gatewayHost,
      publicOrigin: ORIGIN,
      sessions: auth,
      accounts: [
        {
          username: 'fixture-user',
          userId: 'fixture-user',
          passwordHash: await hashGatewayPassword('fixture-only-password'),
        },
      ],
      hosts: new Map([
        [
          'fixture-user',
          {
            userId: 'fixture-user',
            backend: `http://127.0.0.1:${backendPort}`,
            backendOrigin: BACKEND_ORIGIN,
            backendToken: TOKEN,
          },
        ],
      ]),
      assets: new Map([['/', { content: '<html></html>', contentType: 'text/html' }]]),
    })
    const socket = new WebSocket(`ws://127.0.0.1:${gatewayPort}${BUS_PATH}`, {
      origin: ORIGIN,
      headers: { Cookie: sessionCookie(issued.token).split(';')[0] ?? '' },
    })
    clients.push(socket)
    const pending: unknown[] = []
    const waiters: Array<(value: unknown) => void> = []
    socket.on('message', (data) => {
      const message: unknown = JSON.parse(String(data))
      const waiter = waiters.shift()
      if (waiter) waiter(message)
      else pending.push(message)
    })
    const next = () =>
      new Promise<unknown>((resolve, reject) => {
        const value = pending.shift()
        if (value !== undefined) return resolve(value)
        const timeout = setTimeout(() => reject(new Error('real bus reply timeout')), 5000)
        waiters.push((message) => {
          clearTimeout(timeout)
          resolve(message)
        })
      })
    await new Promise<void>((resolve, reject) => {
      socket.once('open', () => resolve())
      socket.once('error', reject)
    })
    expect(await next()).toMatchObject({ kind: 'hello', capabilities: { host: 'node' } })
    socket.send(
      JSON.stringify({
        kind: 'request',
        id: 'r1',
        name: 'terminal.start',
        params: {
          session: 'fixture',
          title: 'Fixture',
          kind: 'Shell',
          cwd: home,
          cols: 80,
          rows: 24,
        },
      }),
    )
    expect(await next()).toMatchObject({
      kind: 'reply',
      id: 'r1',
      result: { session: 'fixture', kind: 'Shell' },
    })
    socket.send(
      JSON.stringify({
        kind: 'request',
        id: 'r2',
        name: 'terminal.list',
        params: {},
      }),
    )
    expect(await next()).toMatchObject({
      kind: 'reply',
      id: 'r2',
      result: { sessions: [{ session: 'fixture' }] },
    })
    socket.send(
      JSON.stringify({
        kind: 'stream',
        session: 'fixture',
        data: { type: 'input', data: 'hello' },
      }),
    )
    expect(await next()).toMatchObject({
      kind: 'stream',
      session: 'fixture',
      data: { type: 'output', data: 'hello' },
    })
    // Simulate closing the browser tab: the host-owned terminal must remain.
    const disconnected = new Promise<void>((resolve) => socket.once('close', () => resolve()))
    socket.close()
    await disconnected
    expect(killed).toBe(false)

    // A new browser connection uses the same authenticated session and must
    // re-attach to the existing terminal, receiving its saved screen snapshot.
    const returned = new WebSocket(`ws://127.0.0.1:${gatewayPort}${BUS_PATH}`, {
      origin: ORIGIN,
      headers: { Cookie: sessionCookie(issued.token).split(';')[0] ?? '' },
    })
    clients.push(returned)
    const returnedQueue: unknown[] = []
    const returnedWaiters: Array<(value: unknown) => void> = []
    returned.on('message', (data) => {
      const message: unknown = JSON.parse(String(data))
      const waiter = returnedWaiters.shift()
      if (waiter) waiter(message)
      else returnedQueue.push(message)
    })
    const nextReturned = () =>
      new Promise<unknown>((resolve, reject) => {
        const value = returnedQueue.shift()
        if (value !== undefined) return resolve(value)
        const timeout = setTimeout(() => reject(new Error('reconnected bus timeout')), 5000)
        returnedWaiters.push((message) => {
          clearTimeout(timeout)
          resolve(message)
        })
      })
    await new Promise<void>((resolve, reject) => {
      returned.once('open', () => resolve())
      returned.once('error', reject)
    })
    expect(await nextReturned()).toMatchObject({ kind: 'hello', capabilities: { host: 'node' } })
    returned.send(
      JSON.stringify({
        kind: 'request',
        id: 'reconnect',
        name: 'terminal.attach',
        params: { session: 'fixture', cols: 80, rows: 24 },
      }),
    )
    // The snapshot can arrive before or after the attachment reply.
    const resumed = [await nextReturned(), await nextReturned()]
    expect(resumed).toContainEqual(
      expect.objectContaining({
        kind: 'reply',
        id: 'reconnect',
        result: expect.objectContaining({ session: 'fixture' }),
      }),
    )
    expect(resumed).toContainEqual(
      expect.objectContaining({
        kind: 'stream',
        session: 'fixture',
        data: expect.objectContaining({
          type: 'snapshot',
          data: expect.stringContaining('hello'),
        }),
      }),
    )
    returned.send(
      JSON.stringify({
        kind: 'stream',
        session: 'fixture',
        data: { type: 'input', data: 'again' },
      }),
    )
    expect(await nextReturned()).toMatchObject({
      kind: 'stream',
      session: 'fixture',
      data: { type: 'output', data: 'again' },
    })
    returned.send(
      JSON.stringify({
        kind: 'request',
        id: 'r3',
        name: 'terminal.close',
        params: { session: 'fixture' },
      }),
    )
    expect(await nextReturned()).toMatchObject({ kind: 'reply', id: 'r3', result: null })
    expect(killed).toBe(true)
  })
})
