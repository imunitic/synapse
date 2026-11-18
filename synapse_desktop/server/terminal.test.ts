import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { Bus } from '../shared/bus.ts'
import { serve, type Connection } from '../shared/dispatch.ts'
import { linkPair } from '../shared/link.ts'
import type { Params } from '../shared/messages.ts'
import type { TerminalHostStream } from '../shared/terminal.ts'
import { terminalHandlers, terminalStream } from './terminal-bus.ts'
import { createSessions, DETACHED_TTL_MS, type Sessions, type Sink } from './terminal-sessions.ts'
import type { Pty, SpawnPty } from './terminal.ts'
import type { Registration, TranscriptEvents, Watcher } from './transcripts.ts'

class FakeWatcher implements Watcher {
  registered: [string, Registration][] = []
  stopped = false
  poll() {
    return Promise.resolve()
  }
  register(id: string, registration: Registration) {
    this.registered.push([id, registration])
  }
  stop() {
    this.stopped = true
  }
}

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
let ptys: FakePty[]
let spawned: {
  file: string
  args: string[]
  cwd: string
  env: Record<string, string>
  cols: number
  rows: number
}[]
let maxTerminals: number
let failSpawn: boolean
let watchers: FakeWatcher[]
let watchEvents: TranscriptEvents[]
let watchDirs: string[]
let sessions: Sessions
let expiries: { ms: number; action: () => void; cancelled: boolean }[]
let connections: { close: () => void }[]
let counter: number

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-terminal-'))
  ptys = []
  spawned = []
  maxTerminals = 8
  failSpawn = false
  watchers = []
  watchEvents = []
  watchDirs = []
  expiries = []
  connections = []
  counter = 0
  await writeFile(
    join(dir, 'config.json'),
    JSON.stringify({
      workDir: '/work',
      definitionPaths: [],
      defaultHarness: null,
      env: { FROM_APP: 'yes' },
      recentVaults: [],
      graphRepos: {},
    }),
  )
  const spawn: SpawnPty = (file, args, options) => {
    if (failSpawn) throw new Error('no such program')
    spawned.push({ file, args, ...options })
    const pty = new FakePty()
    ptys.push(pty)
    return pty
  }
  sessions = createSessions({
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
    sessionsRoot: join(dir, 'sessions'),
    watch: (options) => {
      const watcher = new FakeWatcher()
      watchers.push(watcher)
      watchEvents.push(options.events)
      watchDirs.push(options.dir)
      return watcher
    },
    schedule: (action, ms) => {
      const entry = { ms, action, cancelled: false }
      expiries.push(entry)
      return () => {
        entry.cancelled = true
      }
    },
  })
})

afterEach(async () => {
  for (const connection of connections) connection.close()
  await rm(dir, { recursive: true, force: true })
})

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

async function until(done: () => boolean, ms = 2000): Promise<void> {
  const end = Date.now() + ms
  while (!done()) {
    if (Date.now() > end) throw new Error('timed out')
    await sleep(5)
  }
}

interface Client {
  bus: Bus
  close: () => void
  // What came on the stream of each session.
  streams: Map<string, TerminalHostStream[]>
  watch: (session: string) => TerminalHostStream[]
}

// A connection to the sessions, as the host's bus makes one.
function connect(owner = 'local'): Client {
  const { client, host } = linkPair()
  let connection: Connection | null = null
  const sink: Sink = { send: (session, message) => connection?.stream(session, message) }
  connection = serve(host, {
    handlers: terminalHandlers(sessions, owner, sink),
    capabilities: { host: 'node', shell: true, installActions: false },
    onStream: terminalStream(sessions, owner, sink),
  })
  host.onClose(() => sessions.detachAll(sink))
  const bus = new Bus(client)
  const streams = new Map<string, TerminalHostStream[]>()
  const watch = (session: string) => {
    let seen = streams.get(session)
    if (seen === undefined) {
      seen = []
      streams.set(session, seen)
      const list = seen
      bus.onStream(session, (data) => list.push(data as TerminalHostStream))
    }
    return seen
  }
  const result = { bus, close: () => client.close(), streams, watch }
  connections.push(result)
  return result
}

type Start = Params<'terminal.start'>

// Asks for a session, and says what it was asked for.
function begin(client: Client, fields: Partial<Start> = {}) {
  const session = fields.session ?? `s${++counter}`
  client.watch(session)
  return client.bus.request('terminal.start', {
    session,
    title: 'Terminal',
    kind: 'Claude',
    cwd: dir,
    cols: 100,
    rows: 30,
    ...fields,
  } as Start)
}

const refused = (request: Promise<unknown>) =>
  request.then(
    () => null,
    (error: { code: string; message: string }) => error,
  )

describe('a session started for a task', () => {
  it('gives the harness the sentence as its last argument, after the session it is followed by', async () => {
    await begin(connect(), { task: 'rebuild-diff' })
    const args = spawned[0]?.args ?? []
    expect(args.slice(0, 2)).toEqual(['--injected', '--session-id'])
    expect(args.at(-1)).toBe('Do a synapse rebuild diff.')
    expect(args).toHaveLength(4)
  })

  it('gives OpenCode the sentence after --prompt, and Codex the same sentence as its last argument', async () => {
    const client = connect()
    await begin(client, { kind: 'Opencode', task: 'rebuild-full' })
    expect(spawned[0]?.args.slice(-2)).toEqual(['--prompt', 'Do a synapse rebuild full.'])
    await begin(client, { kind: 'Codex', task: 'init' })
    expect(spawned[1]?.args.at(-1)).toBe('Do a synapse init.')
  })

  it('is refused for a shell, which has no prompt, and for a task it does not know', async () => {
    const client = connect()
    expect(await refused(begin(client, { kind: 'Shell', task: 'init' }))).toMatchObject({
      code: 'bad_request',
      message: 'a shell has no task to start',
    })
    expect(
      await refused(begin(client, { task: 'rm -rf' } as unknown as Partial<Start>)),
    ).toMatchObject({
      code: 'bad_request',
    })
    expect(spawned).toEqual([])
  })
})

describe('an interactive run of a pipeline', () => {
  const run = (fields: Partial<Start>) => ({ kind: 'Pipeline', ...fields }) as Partial<Start>

  it('starts synapse-pipeline with an id of its own, which the page is told', async () => {
    const info = await begin(connect(), run({ pipeline: 'Develop_Review_Loop' }))
    expect(info.executionId).toMatch(/^exec-[0-9a-f]{8}$/)
    const args = spawned[0]?.args ?? []
    expect(args.slice(0, 4)).toEqual(['--injected', 'run', 'Develop_Review_Loop', '--interactive'])
    expect(args.slice(4, 6)).toEqual(['--id', info.executionId])
    expect(args).not.toContain('--input')
  })

  it("gives the input in a file, since the terminal is the harness's", async () => {
    await begin(connect(), run({ pipeline: 'Dev', input: { task: 'add a flag' } }))
    const args = spawned[0]?.args ?? []
    const file = args[args.indexOf('--input') + 1] ?? ''
    expect(file.startsWith(join(dir, 'sessions'))).toBe(true)
    expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ task: 'add a flag' })
  })

  it('is refused without a pipeline, with a task, and for any other kind', async () => {
    for (const [fields, message] of [
      [run({}), 'an interactive run needs a pipeline'],
      [run({ pipeline: 'Dev', task: 'init' }), 'a pipeline has no task or session to resume'],
      [{ pipeline: 'Dev', kind: 'Shell' } as const, 'only an interactive run takes a pipeline'],
    ] as const) {
      expect(await refused(begin(connect(), fields))).toMatchObject({ message })
    }
    expect(spawned).toEqual([])
  })

  it('does not take a name that is not a name', async () => {
    expect(await refused(begin(connect(), run({ pipeline: '../x; rm -rf /' })))).toMatchObject({
      code: 'bad_request',
    })
    expect(spawned).toEqual([])
  })
})

describe('a session that is resumed', () => {
  const resumed = async (kind: Start['kind'], resume: string, index = 0) => {
    await begin(connect(), { kind, resume })
    return spawned[index]?.args ?? []
  }

  it('continues the session by its id, in the way of each harness', async () => {
    expect((await resumed('Claude', 'abc-123')).slice(-2)).toEqual(['--resume', 'abc-123'])
    expect((await resumed('Opencode', 'ses_abc', 1)).slice(-2)).toEqual(['--session', 'ses_abc'])
    expect((await resumed('Codex', 'def-456', 2)).slice(-2)).toEqual(['resume', 'def-456'])
  })

  it('is not given a new session of our own', async () => {
    expect(await resumed('Claude', 'abc-123')).not.toContain('--session-id')
  })

  it('is refused for a shell, for a task, and for an id that could be taken for a flag', async () => {
    const client = connect()
    expect(await refused(begin(client, { kind: 'Shell', resume: 'abc' }))).not.toBeNull()
    expect(await refused(begin(client, { task: 'init', resume: 'abc' }))).not.toBeNull()
    expect(
      await refused(begin(client, { resume: '--dangerously-skip-permissions' })),
    ).not.toBeNull()
    expect(spawned).toEqual([])
  })
})

describe('a session', () => {
  it('takes ~ for the home folder in the folder it is asked to start in', async () => {
    // The environment of the test has `dir` as its home.
    await begin(connect(), { kind: 'Shell', cwd: '~' })
    expect(spawned[0]).toMatchObject({ file: 'shell', cwd: dir })
  })

  it('starts the shell in the home folder when no folder is given', async () => {
    await begin(connect(), { kind: 'Shell', cwd: undefined })
    expect(spawned[0]).toMatchObject({ file: 'shell', cwd: dir })
  })

  it('starts the program the plan names, in the folder, with the app variables, and relays what it prints and what is typed', async () => {
    const client = connect()
    const info = await begin(client, { session: 'main' })
    expect(info).toMatchObject({
      session: 'main',
      title: 'Terminal',
      kind: 'Claude',
      cwd: dir,
      loaded: true,
      note: 'loaded for this session',
      exited: null,
    })
    expect(spawned).toHaveLength(1)
    expect(spawned[0]).toMatchObject({ file: 'claude', cwd: dir, cols: 100, rows: 30 })
    // The plan's arguments, then the session the server gives Claude to follow.
    expect(spawned[0]?.args.slice(0, 2)).toEqual(['--injected', '--session-id'])
    // The server's own environment, the variables set in the app, then the plan's.
    expect(spawned[0]?.env).toMatchObject({
      INHERITED: 'i',
      FROM_APP: 'yes',
      PLAN_ENV: 'p',
      TERM: 'xterm-256color',
    })

    ptys[0]?.print('hello')
    await until(() => client.watch('main').length > 0)
    expect(client.watch('main')).toEqual([{ type: 'output', data: 'hello' }])
    client.bus.stream('main', { type: 'input', data: 'ls\r' })
    client.bus.stream('main', { type: 'resize', cols: 120, rows: 40 })
    await until(() => ptys[0]?.resized.length === 1)
    expect(ptys[0]?.written).toEqual(['ls\r'])
    expect(ptys[0]?.resized).toEqual([[120, 40]])
  })

  it('does not hand a terminal the identity of the session the server runs in', async () => {
    await begin(connect())
    expect(spawned[0]?.env).not.toHaveProperty('CLAUDECODE')
    expect(spawned[0]?.env).not.toHaveProperty('CLAUDE_CODE_CHILD_SESSION')
    expect(spawned[0]?.env).not.toHaveProperty('CLAUDE_CODE_MESSAGING_TOKEN')
    // The rest of the environment is as it was.
    expect(spawned[0]?.env).toMatchObject({ INHERITED: 'i', CLAUDE_EFFORT: 'high' })
  })

  it('says how the program ended, and keeps the session to be read until its tab is closed', async () => {
    const client = connect()
    await begin(client, { session: 'main' })
    ptys[0]?.end(3)
    await until(() => client.watch('main').length > 0)
    expect(client.watch('main')).toEqual([{ type: 'exit', code: 3 }])
    const { sessions: listed } = await client.bus.request('terminal.list', {})
    expect(listed).toMatchObject([{ session: 'main', exited: 3 }])
    expect(watchers[0]?.stopped).toBe(true)
    await client.bus.request('terminal.close', { session: 'main' })
    expect((await client.bus.request('terminal.list', {})).sessions).toEqual([])
    // The program had ended: there is nothing to kill.
    expect(ptys[0]?.killed).toBe(false)
  })

  it('refuses a folder that is not one, a relative path and a program that cannot start', async () => {
    for (const cwd of [join(dir, 'missing'), 'relative/path', join(dir, 'config.json')]) {
      expect(await refused(begin(connect(), { cwd }))).toMatchObject({
        code: 'bad_request',
        message: expect.stringContaining('not a folder'),
      })
    }
    expect(spawned).toEqual([])

    failSpawn = true
    expect(await refused(begin(connect()))).toMatchObject({
      code: 'unavailable',
      message: expect.stringContaining('could not be started'),
    })
  })

  it('does not start two sessions of one name', async () => {
    const client = connect()
    await begin(client, { session: 'same' })
    expect(await refused(begin(client, { session: 'same' }))).toMatchObject({
      code: 'conflict',
      message: expect.stringContaining('started already'),
    })
    expect(spawned).toHaveLength(1)
  })

  it('holds the number of open terminals to the limit, and frees a place when one is closed', async () => {
    maxTerminals = 1
    const client = connect()
    await begin(client, { session: 'first' })
    expect(await refused(begin(client))).toMatchObject({
      code: 'conflict',
      message: expect.stringContaining('too many'),
    })
    await client.bus.request('terminal.close', { session: 'first' })
    await begin(client)
  })

  it('does not count a session whose program has ended against the limit', async () => {
    maxTerminals = 1
    const client = connect()
    await begin(client)
    ptys[0]?.end(0)
    await begin(client)
  })
})

describe('a session that is held by the host', () => {
  it('keeps running when the connection drops, and a new connection attaches to it', async () => {
    const first = connect()
    await begin(first, { session: 'main' })
    first.close()
    await sleep(20)
    expect(ptys[0]?.killed).toBe(false)

    const second = connect()
    const attached = await second.bus.request('terminal.attach', {
      session: 'main',
      cols: 90,
      rows: 20,
    })
    expect(attached).toMatchObject({ session: 'main', kind: 'Claude', exited: null })
    expect(ptys[0]?.resized).toEqual([[90, 20]])
    expect((await second.bus.request('terminal.list', {})).sessions).toHaveLength(1)
  })

  it('gives the screen as the program drew it when a client attaches, then what it prints', async () => {
    const first = connect()
    await begin(first, { session: 'main', cols: 20, rows: 4 })
    ptys[0]?.print('one\r\ntwo\r\n\x1b[31mred\x1b[0m')
    first.close()

    const second = connect()
    second.watch('main')
    await second.bus.request('terminal.attach', { session: 'main', cols: 20, rows: 4 })
    await until(() => second.watch('main').length > 0)
    const [snapshot] = second.watch('main')
    expect(snapshot).toMatchObject({ type: 'snapshot' })
    expect((snapshot as { data: string }).data).toContain('one\r\ntwo\r\n')
    expect((snapshot as { data: string }).data).toContain('\x1b[31mred')

    ptys[0]?.print('!')
    await until(() => second.watch('main').length > 1)
    expect(second.watch('main')[1]).toEqual({ type: 'output', data: '!' })
  })

  it('keeps a screen drawn on the alternate screen, which a harness draws on', async () => {
    const first = connect()
    await begin(first, { session: 'main', cols: 20, rows: 4 })
    ptys[0]?.print('\x1b[?1049h\x1b[2J\x1b[HALT SCREEN')
    const second = connect()
    second.watch('main')
    await second.bus.request('terminal.attach', { session: 'main', cols: 20, rows: 4 })
    await until(() => second.watch('main').length > 0)
    const data = (second.watch('main')[0] as { data: string }).data
    expect(data).toContain('\x1b[?1049h')
    expect(data).toContain('ALT SCREEN')
  })

  it('keeps 100 lines above the screen and no more', async () => {
    const first = connect()
    await begin(first, { session: 'main', cols: 20, rows: 4 })
    for (let line = 1; line <= 300; line++) ptys[0]?.print(`line ${line}\r\n`)
    const second = connect()
    second.watch('main')
    await second.bus.request('terminal.attach', { session: 'main', cols: 20, rows: 4 })
    await until(() => second.watch('main').length > 0)
    const data = (second.watch('main')[0] as { data: string }).data
    expect(data).toContain('line 300')
    expect(data).toContain('line 200')
    expect(data).not.toContain('line 190\r')
    expect(data).not.toContain('line 1\r')
  })

  it('sends an ended session its exit after the screen', async () => {
    const first = connect()
    await begin(first, { session: 'main' })
    ptys[0]?.print('bye')
    ptys[0]?.end(5)
    const second = connect()
    second.watch('main')
    await second.bus.request('terminal.attach', { session: 'main', cols: 80, rows: 24 })
    await until(() => second.watch('main').length >= 2)
    expect(second.watch('main').map((m) => m.type)).toEqual(['snapshot', 'exit'])
    // There is no program to resize.
    expect(ptys[0]?.resized).toEqual([])
  })

  it('belongs to the user who started it, and only that user can attach, type, close or list it', async () => {
    const owner = connect('ann')
    await begin(owner, { session: 'main' })
    const other = connect('bob')
    expect(
      await refused(other.bus.request('terminal.attach', { session: 'main', cols: 80, rows: 24 })),
    ).toMatchObject({ code: 'forbidden' })
    expect(await refused(other.bus.request('terminal.close', { session: 'main' }))).toMatchObject({
      code: 'forbidden',
    })
    expect((await other.bus.request('terminal.list', {})).sessions).toEqual([])
    other.bus.stream('main', { type: 'input', data: 'rm -rf /\r' })
    await sleep(30)
    expect(ptys[0]?.written).toEqual([])
    expect((await owner.bus.request('terminal.list', {})).sessions).toHaveLength(1)
  })

  it('does not take typing from a connection that is not attached to it', async () => {
    const owner = connect()
    await begin(owner, { session: 'main' })
    owner.close()
    const second = connect()
    second.bus.stream('main', { type: 'input', data: 'x' })
    await sleep(30)
    expect(ptys[0]?.written).toEqual([])
    await second.bus.request('terminal.attach', { session: 'main', cols: 80, rows: 24 })
    second.bus.stream('main', { type: 'input', data: 'y' })
    await until(() => ptys[0]?.written.length === 1)
    expect(ptys[0]?.written).toEqual(['y'])
  })

  it('says it is not there for a session that is not', async () => {
    const client = connect()
    expect(
      await refused(client.bus.request('terminal.attach', { session: 'nope', cols: 80, rows: 24 })),
    ).toMatchObject({ code: 'not_found' })
  })

  it('ends with its tab: the program is killed, the conversation is no longer followed', async () => {
    const client = connect()
    await begin(client, { session: 'main' })
    await client.bus.request('terminal.close', { session: 'main' })
    expect(ptys[0]?.killed).toBe(true)
    expect(watchers[0]?.stopped).toBe(true)
    expect(
      await refused(client.bus.request('terminal.attach', { session: 'main', cols: 80, rows: 24 })),
    ).toMatchObject({ code: 'not_found' })
  })

  it('ends after twelve hours with no client attached, and not while one is', async () => {
    const client = connect()
    await begin(client, { session: 'main' })
    // A client is attached: nothing is waiting to end it.
    expect(expiries).toEqual([])
    client.close()
    await sleep(20)
    expect(expiries).toHaveLength(1)
    expect(expiries[0]?.ms).toBe(DETACHED_TTL_MS)
    expect(DETACHED_TTL_MS).toBe(12 * 3600 * 1000)

    // Attaching again withdraws it, and detaching sets it again.
    const second = connect()
    await second.bus.request('terminal.attach', { session: 'main', cols: 80, rows: 24 })
    expect(expiries[0]?.cancelled).toBe(true)
    second.close()
    await sleep(20)
    expect(expiries).toHaveLength(2)
    expect(ptys[0]?.killed).toBe(false)

    expiries[1]?.action()
    expect(ptys[0]?.killed).toBe(true)
    const third = connect()
    expect(
      await refused(third.bus.request('terminal.attach', { session: 'main', cols: 80, rows: 24 })),
    ).toMatchObject({ code: 'not_found' })
  })

  it('stays attached while another client of the same session is', async () => {
    const first = connect()
    await begin(first, { session: 'main' })
    const second = connect()
    await second.bus.request('terminal.attach', { session: 'main', cols: 80, rows: 24 })
    first.close()
    await sleep(20)
    expect(expiries).toEqual([])
  })
})

describe('following the conversation of a harness', () => {
  async function startKind(kind: Start['kind'], client = connect()) {
    await begin(client, { kind, session: `k-${kind}-${++counter}` })
    return client
  }

  it('gives a Claude tab a session of its own and follows its file', async () => {
    const client = connect()
    await begin(client, { session: 'main' })
    const args = spawned[0]?.args ?? []
    expect(args.slice(0, 1)).toEqual(['--injected'])
    expect(args[1]).toBe('--session-id')
    const id = args[2] ?? ''
    expect(id).toMatch(/^[0-9a-f-]{36}$/)
    expect(watchers[0]?.registered).toEqual([
      [id, expect.objectContaining({ harness: 'claude', sessionId: id, cwd: dir })],
    ])

    // What the watcher finds goes to the page.
    watchEvents[0]?.onSource({ id, harness: 'Claude', cwd: dir })
    watchEvents[0]?.onLines(id, ['{"a":1}', '{"b":2}'])
    await until(() => client.watch('main').length >= 2)
    expect(client.watch('main')).toEqual([
      { type: 'transcript-source', id, harness: 'Claude', cwd: dir },
      { type: 'transcript', id, lines: ['{"a":1}', '{"b":2}'] },
    ])
  })

  it('gives it all again to a client that attaches later', async () => {
    const first = connect()
    await begin(first, { session: 'main' })
    const id = spawned[0]?.args[2] ?? ''
    watchEvents[0]?.onSource({ id, harness: 'Claude', cwd: dir })
    watchEvents[0]?.onLines(id, ['{"a":1}'])
    watchEvents[0]?.onLines(id, ['{"b":2}'])
    first.close()
    const second = connect()
    second.watch('main')
    await second.bus.request('terminal.attach', { session: 'main', cols: 80, rows: 24 })
    await until(() => second.watch('main').length >= 3)
    expect(second.watch('main').map((m) => m.type)).toEqual([
      'snapshot',
      'transcript-source',
      'transcript',
    ])
    expect(second.watch('main')[2]).toEqual({
      type: 'transcript',
      id,
      lines: ['{"a":1}', '{"b":2}'],
    })
  })

  it('notes a Codex tab by where it started and where it keeps its sessions', async () => {
    await startKind('Codex')
    const [registration] = watchers[0]?.registered ?? []
    expect(registration?.[1]).toMatchObject({ harness: 'codex', cwd: dir })
    expect(spawned[0]?.args).toEqual(['--injected'])
  })

  it('gives an OpenCode tab a session id of its own and follows that session', async () => {
    await startKind('Opencode')
    const args = spawned[0]?.args ?? []
    expect(args.slice(0, 1)).toEqual(['--injected'])
    expect(args[1]).toBe('--session')
    const id = args[2] ?? ''
    expect(id).toMatch(/^ses_[0-9a-f]{20}$/)
    expect(watchers[0]?.registered).toEqual([
      [id, expect.objectContaining({ harness: 'opencode', sessionId: id, cwd: dir })],
    ])
  })

  it('gives a shell the folder its commands note runs in, and follows nothing itself', async () => {
    await startKind('Shell')
    expect(watchers[0]?.registered).toEqual([])
    const shell = spawned[0]
    expect(shell?.args).toEqual(['--injected'])
    expect(shell?.env.SYNAPSE_SESSIONS_DIR).toBe(watchDirs[0])
    expect(watchDirs[0]?.startsWith(join(dir, 'sessions') + '/')).toBe(true)
    // Each terminal has a folder of its own.
    await startKind('Shell')
    expect(watchDirs[0]).not.toBe(watchDirs[1])
  })
})
