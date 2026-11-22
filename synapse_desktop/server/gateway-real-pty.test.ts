// End-to-end repository-only smoke test: authenticated gateway -> real Node bus -> OS PTY.
// Both listeners bind loopback; the shell runs in a disposable directory without agents.
import { mkdtemp, rm } from 'node:fs/promises'
import { createServer, type Server } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { WebSocket } from 'ws'
import { BUS_PATH } from '../shared/constants.ts'
import { attachBus } from './bus.ts'
import { attachSessionGateway } from './gateway-session-adapter.ts'
import { createGatewaySessions, sessionCookie } from './gateway-sessions.ts'
import { createSessions } from './terminal-sessions.ts'
import { spawnPty, type Pty } from './terminal.ts'
import { NotStartedHere, RunNotStarted } from './runs.ts'

const ORIGIN = 'https://synapse.example.test'
const INTERNAL_ORIGIN = 'http://gateway.internal'
const TOKEN = 'private-pty-test-token'
const servers: Server[] = []
const sockets: WebSocket[] = []
const processes: Pty[] = []
const directories: string[] = []

async function listen(server: Server): Promise<number> {
  servers.push(server)
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('invalid address')
  return address.port
}

afterEach(async () => {
  for (const socket of sockets.splice(0)) socket.terminate()
  for (const process of processes.splice(0)) process.kill()
  await Promise.all(servers.splice(0).map((server) =>
    new Promise<void>((resolve) => server.close(() => resolve())),
  ))
  await Promise.all(directories.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe.skipIf(process.platform === 'win32')('authenticated gateway to real Node PTY', () => {
  it('rejects unauthenticated clients and executes shell input for an authenticated client', async () => {
    const home = await mkdtemp(join(tmpdir(), 'synapse-gateway-pty-'))
    directories.push(home)
    const configFile = join(home, 'config.json')
    const sessions = createSessions({
      environment: { env: { PATH: '/usr/bin:/bin', HOME: home, SHELL: '/bin/sh' }, home },
      configFile,
      sessionsRoot: join(home, 'sessions'),
      maxTerminals: 1,
      plan: async () => ({ command: '/bin/sh', args: [], env: {}, loaded: false, note: '' }),
      spawn: (file, args, options) => {
        const pty = spawnPty(file, args, options)
        processes.push(pty)
        return pty
      },
      watch: () => ({
        stop: () => undefined,
        poll: async () => undefined,
        register: () => undefined,
      }),
    })
    const backend = createServer()
    const allowedHosts = new Set<string>()
    attachBus(backend, {
      policy: { allowedHosts, allowedOrigins: new Set([INTERNAL_ORIGIN]), token: TOKEN },
      sessions,
      context: {
        environment: { env: { XDG_CONFIG_HOME: join(home, 'xdg') }, home },
        configFile,
        runs: {
          start: () => Promise.reject(new RunNotStarted('not used')),
          stop: () => { throw new NotStartedHere('not used') },
        },
        agent: () => Promise.reject(new Error('not used')),
        noteSession: () => Promise.reject(new Error('not used')),
        runCli: () => Promise.resolve({ code: 0, stdout: '', stderr: '' }),
      },
      report: () => undefined,
    })
    const backendPort = await listen(backend)
    allowedHosts.add(`127.0.0.1:${backendPort}`)

    const auth = createGatewaySessions()
    const issued = auth.issue('alice')
    const gateway = createServer()
    const gatewayPort = await listen(gateway)
    attachSessionGateway(gateway, {
      publicHost: `127.0.0.1:${gatewayPort}`,
      publicOrigin: ORIGIN,
      hosts: new Map([['alice', {
        userId: 'alice',
        backend: `http://127.0.0.1:${backendPort}`,
        backendToken: TOKEN,
        backendOrigin: INTERNAL_ORIGIN,
      }]]),
      sessions: auth,
      recheckMs: 20,
    })

    const open = (cookie?: string) => new Promise<WebSocket | number>((resolve) => {
      const socket = new WebSocket(`ws://127.0.0.1:${gatewayPort}${BUS_PATH}`, {
        origin: ORIGIN,
        headers: cookie ? { cookie } : {},
      })
      sockets.push(socket)
      socket.once('open', () => resolve(socket))
      socket.once('unexpected-response', (_request, response) => resolve(response.statusCode ?? 0))
      socket.once('error', () => resolve(0))
    })
    expect(await open()).toBe(401)
    const connected = await open(sessionCookie(issued.token).split(';')[0])
    if (typeof connected === 'number') throw new Error('authenticated connection refused')

    const messages: unknown[] = []
    connected.on('message', (data) => messages.push(JSON.parse(String(data))))
    await expect.poll(() => messages.some((m) =>
      typeof m === 'object' && m !== null && 'kind' in m && m.kind === 'hello',
    )).toBe(true)
    connected.send(JSON.stringify({
      kind: 'request', id: 'start', name: 'terminal.start',
      params: { session: 'gateway-shell', title: 'Shell', kind: 'Shell', cwd: home, cols: 80, rows: 24 },
    }))
    await expect.poll(() => messages.some((m) =>
      typeof m === 'object' && m !== null && 'kind' in m && m.kind === 'reply' &&
      'id' in m && m.id === 'start' && 'result' in m,
    )).toBe(true)
    connected.send(JSON.stringify({
      kind: 'stream', session: 'gateway-shell',
      data: { type: 'input', data: "printf 'SYNAPSE_GATEWAY_REAL_PTY_OK\\n'\n" },
    }))
    await expect.poll(() => JSON.stringify(messages)).toContain('SYNAPSE_GATEWAY_REAL_PTY_OK')
    sessions.close('gateway-shell', 'local')
  }, 20_000)
})
