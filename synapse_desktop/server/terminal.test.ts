import { createServer, type Server } from 'node:http'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { WebSocket } from 'ws'
import { TERMINAL_PATH, TOKEN_HEADER } from '../shared/constants.ts'
import type { ServerMessage } from '../shared/terminal.ts'
import { attachTerminals, type Pty, type SpawnPty } from './terminal.ts'

const TOKEN = 'secret-token'

class FakePty implements Pty {
  written: string[] = []
  resized: [number, number][] = []
  killed = false
  private data: ((d: string) => void) | null = null
  private exit: ((e: { exitCode: number }) => void) | null = null
  onData(listener: (d: string) => void) {
    this.data = listener
  }
  onExit(listener: (e: { exitCode: number }) => void) {
    this.exit = listener
  }
  write(d: string) {
    this.written.push(d)
  }
  resize(c: number, r: number) {
    this.resized.push([c, r])
  }
  kill() {
    this.killed = true
  }
  print(d: string) {
    this.data?.(d)
  }
  end(code: number) {
    this.exit?.({ exitCode: code })
  }
}

let dir: string
let server: Server
let port: number
let ptys: FakePty[]
let spawned: {
  file: string
  args: string[]
  cwd: string
  env: Record<string, string>
  cols: number
  rows: number
}[]
let sockets: WebSocket[]
let maxTerminals: number
let failSpawn: boolean

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-terminal-'))
  ptys = []
  spawned = []
  sockets = []
  maxTerminals = 8
  failSpawn = false
  await writeFile(
    join(dir, 'config.json'),
    JSON.stringify({
      workDir: '/work',
      definitionPaths: [],
      defaultHarness: null,
      env: { FROM_APP: 'yes' },
      recentVaults: [],
    }),
  )
  const spawn: SpawnPty = (file, args, options) => {
    if (failSpawn) throw new Error('no such program')
    spawned.push({ file, args, ...options })
    const pty = new FakePty()
    ptys.push(pty)
    return pty
  }
  server = createServer()
  const hosts = new Set<string>()
  attachTerminals(server, {
    policy: {
      allowedHosts: hosts,
      allowedOrigins: new Set(['http://127.0.0.1:5173']),
      token: TOKEN,
    },
    environment: {
      env: {
        PATH: '/usr/bin',
        INHERITED: 'i',
        CLAUDE_EFFORT: 'high',
        CLAUDECODE: '1',
        CLAUDE_CODE_CHILD_SESSION: '1',
        CLAUDE_CODE_MESSAGING_TOKEN: 'secret',
      },
      home: dir,
    },
    configFile: join(dir, 'config.json'),
    spawn,
    plan: (kind) =>
      Promise.resolve({
        command: kind.toLowerCase(),
        args: ['--injected'],
        env: { PLAN_ENV: 'p' },
        loaded: true,
        note: 'loaded for this session',
      }),
    get maxTerminals() {
      return maxTerminals
    },
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  port = (server.address() as AddressInfo).port
  hosts.add(`127.0.0.1:${port}`)
})

afterEach(async () => {
  for (const socket of sockets) socket.close()
  server.closeAllConnections()
  await new Promise((resolve) => server.close(resolve))
  await rm(dir, { recursive: true, force: true })
})

function connect(headers: Record<string, string> = {}): WebSocket {
  const socket = new WebSocket(`ws://127.0.0.1:${port}${TERMINAL_PATH}`, {
    headers: { origin: 'http://127.0.0.1:5173', [TOKEN_HEADER]: TOKEN, ...headers },
  })
  sockets.push(socket)
  return socket
}

// The messages a socket receives, in order, and a way to wait for the next.
function inbox(socket: WebSocket) {
  const received: ServerMessage[] = []
  const waiting: ((m: ServerMessage) => void)[] = []
  socket.on('message', (raw) => {
    const message = JSON.parse(String(raw)) as ServerMessage
    const next = waiting.shift()
    if (next) next(message)
    else received.push(message)
  })
  return {
    received,
    next: (): Promise<ServerMessage> =>
      received.length > 0
        ? Promise.resolve(received.shift() as ServerMessage)
        : new Promise((resolve) => waiting.push(resolve)),
  }
}

function opened(socket: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    socket.once('open', resolve)
    socket.once('error', reject)
  })
}

function closed(socket: WebSocket): Promise<void> {
  return new Promise((resolve) =>
    socket.readyState === socket.CLOSED ? resolve() : socket.once('close', () => resolve()),
  )
}

// The status a handshake was refused with.
function refusedWith(socket: WebSocket): Promise<number> {
  return new Promise((resolve, reject) => {
    socket.once('unexpected-response', (_request, response) => resolve(response.statusCode ?? 0))
    socket.once('open', () => reject(new Error('the handshake was accepted')))
    socket.once('error', () => undefined)
  })
}

const start = (cwd?: string, kind = 'Claude') =>
  JSON.stringify({
    type: 'start',
    kind,
    ...(cwd === undefined ? {} : { cwd }),
    cols: 100,
    rows: 30,
  })

describe('the handshake', () => {
  it('is refused without the token, from a foreign origin and for another host', async () => {
    expect(await refusedWith(connect({ [TOKEN_HEADER]: 'wrong' }))).toBe(401)
    expect(await refusedWith(connect({ origin: 'http://evil.example' }))).toBe(403)
    expect(await refusedWith(connect({ host: 'evil.example' }))).toBe(403)
    expect(spawned).toEqual([])
  })

  it('is not accepted on another path', async () => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/api/other`, {
      headers: { origin: 'http://127.0.0.1:5173', [TOKEN_HEADER]: TOKEN },
    })
    sockets.push(socket)
    await new Promise((resolve) => socket.once('error', resolve))
  })
})

describe('a session', () => {
  it('starts the shell in the home folder when no folder is given', async () => {
    const socket = connect()
    const messages = inbox(socket)
    await opened(socket)
    socket.send(start(undefined, 'Shell'))
    expect(await messages.next()).toMatchObject({ type: 'started' })
    // The environment of the test has `dir` as its home.
    expect(spawned[0]).toMatchObject({ file: 'shell', cwd: dir })
  })

  it('starts the program the plan names, in the folder, with the app variables, and relays what it prints and what is typed', async () => {
    const socket = connect()
    const messages = inbox(socket)
    await opened(socket)
    socket.send(start(dir))
    expect(await messages.next()).toEqual({
      type: 'started',
      loaded: true,
      note: 'loaded for this session',
    })

    expect(spawned).toHaveLength(1)
    expect(spawned[0]).toMatchObject({
      file: 'claude',
      args: ['--injected'],
      cwd: dir,
      cols: 100,
      rows: 30,
    })
    // The server's own environment, the variables set in the app, then the plan's.
    expect(spawned[0]?.env).toMatchObject({
      INHERITED: 'i',
      FROM_APP: 'yes',
      PLAN_ENV: 'p',
      TERM: 'xterm-256color',
    })

    ptys[0]?.print('hello')
    expect(await messages.next()).toEqual({ type: 'output', data: 'hello' })
    socket.send(JSON.stringify({ type: 'input', data: 'ls\r' }))
    socket.send(JSON.stringify({ type: 'resize', cols: 120, rows: 40 }))
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(ptys[0]?.written).toEqual(['ls\r'])
    expect(ptys[0]?.resized).toEqual([[120, 40]])
  })

  it('does not hand a terminal the identity of the session the server runs in', async () => {
    const socket = connect()
    const messages = inbox(socket)
    await opened(socket)
    socket.send(start(dir))
    await messages.next()
    expect(spawned[0]?.env).not.toHaveProperty('CLAUDECODE')
    expect(spawned[0]?.env).not.toHaveProperty('CLAUDE_CODE_CHILD_SESSION')
    expect(spawned[0]?.env).not.toHaveProperty('CLAUDE_CODE_MESSAGING_TOKEN')
    // The rest of the environment is as it was.
    expect(spawned[0]?.env).toMatchObject({ INHERITED: 'i', CLAUDE_EFFORT: 'high' })
  })

  it('says how the program ended and closes', async () => {
    const socket = connect()
    const messages = inbox(socket)
    await opened(socket)
    socket.send(start(dir))
    await messages.next()
    ptys[0]?.end(3)
    expect(await messages.next()).toEqual({ type: 'exit', code: 3 })
    await closed(socket)
  })

  it('ends the program when the page goes away', async () => {
    const socket = connect()
    const messages = inbox(socket)
    await opened(socket)
    socket.send(start(dir))
    await messages.next()
    socket.close()
    await closed(socket)
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(ptys[0]?.killed).toBe(true)
  })

  it('refuses a folder that is not one, a relative path and a program that cannot start', async () => {
    for (const cwd of [join(dir, 'missing'), 'relative/path', join(dir, 'config.json')]) {
      const socket = connect()
      const messages = inbox(socket)
      await opened(socket)
      socket.send(start(cwd))
      expect(await messages.next()).toMatchObject({
        type: 'error',
        message: expect.stringContaining('not a folder'),
      })
      await closed(socket)
    }
    expect(spawned).toEqual([])

    failSpawn = true
    const socket = connect()
    const messages = inbox(socket)
    await opened(socket)
    socket.send(start(dir))
    expect(await messages.next()).toMatchObject({
      type: 'error',
      message: expect.stringContaining('could not be started'),
    })
  })

  it('refuses a message that is not one a terminal takes, and ignores typing before the start', async () => {
    const early = connect()
    await opened(early)
    early.send(JSON.stringify({ type: 'input', data: 'x' }))
    early.send(JSON.stringify({ type: 'resize', cols: 10, rows: 10 }))
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(ptys).toEqual([])

    for (const bad of [
      'not json',
      JSON.stringify({ type: 'start', kind: 'Bash', cwd: dir, cols: 1, rows: 1 }),
      JSON.stringify({ type: 'start', kind: 'Claude', cwd: dir, cols: 0, rows: 1 }),
    ]) {
      const socket = connect()
      const messages = inbox(socket)
      await opened(socket)
      socket.send(bad)
      expect(await messages.next()).toMatchObject({ type: 'error' })
      await closed(socket)
    }
    expect(spawned).toEqual([])
  })

  it('does not start a second program on one connection', async () => {
    const socket = connect()
    const messages = inbox(socket)
    await opened(socket)
    socket.send(start(dir))
    await messages.next()
    socket.send(start(dir))
    expect(await messages.next()).toMatchObject({
      type: 'error',
      message: expect.stringContaining('started already'),
    })
    expect(spawned).toHaveLength(1)
  })

  it('holds the number of open terminals to the limit, and frees a place when one closes', async () => {
    maxTerminals = 1
    const first = connect()
    const firstMessages = inbox(first)
    await opened(first)
    first.send(start(dir))
    await firstMessages.next()

    const second = connect()
    const secondMessages = inbox(second)
    await opened(second)
    second.send(start(dir))
    expect(await secondMessages.next()).toMatchObject({
      type: 'error',
      message: expect.stringContaining('too many'),
    })

    first.close()
    await closed(first)
    await new Promise((resolve) => setTimeout(resolve, 50))
    const third = connect()
    const thirdMessages = inbox(third)
    await opened(third)
    third.send(start(dir))
    expect(await thirdMessages.next()).toMatchObject({ type: 'started' })
  })
})
