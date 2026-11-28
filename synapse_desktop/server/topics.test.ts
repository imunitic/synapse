import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { createServer, type Server } from 'node:net'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Context } from './calls.ts'
import { shortSocketFolder, socketPath } from './run-socket.ts'
import { createNoteRuns } from './note-runs.ts'
import { createTopics } from './topics.ts'

let dir: string
let context: Context
const stops: (() => void)[] = []

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

async function until(done: () => boolean, ms = 3000): Promise<void> {
  const end = Date.now() + ms
  while (!done()) {
    if (Date.now() > end) throw new Error('timed out')
    await sleep(20)
  }
}

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-topics-'))
  await mkdir(join(dir, 'work', 'pipelines'), { recursive: true })
  await writeFile(
    join(dir, 'config.json'),
    JSON.stringify({ workDir: join(dir, 'work'), definitionPaths: [], defaultHarness: null }),
  )
  context = {
    environment: { env: { XDG_CONFIG_HOME: join(dir, 'xdg') }, home: dir },
    configFile: join(dir, 'config.json'),
    runs: {
      start: () => Promise.reject(new Error('no')),
      stop: () => undefined,
      stopAll: () => undefined,
    },
    agent: () => Promise.reject(new Error('no')),
    noteRuns: createNoteRuns(),
    noteSession: () => Promise.reject(new Error('no')),
    runCli: () =>
      Promise.resolve({
        code: 0,
        stdout: JSON.stringify({
          settings: [{ key: 'SYNAPSE_VAULT_DIR', value: join(dir, 'vault') }],
        }),
        stderr: '',
      }),
  }
})

afterEach(async () => {
  for (const stop of stops.splice(0)) stop()
  await rm(dir, { recursive: true, force: true })
})

// A watcher may report what happened just before it was made, which is not a change after it; this
// waits that out and forgets it.
async function settle(seen: unknown[]): Promise<void> {
  await sleep(400)
  seen.length = 0
}

function subscribed(
  topic: Parameters<ReturnType<typeof createTopics>>[0],
  after?: number,
  options: Partial<Parameters<typeof createTopics>[0]> = {},
) {
  const seen: { data: unknown; cursor: number | undefined }[] = []
  const subscribe = createTopics({ context, debounceMs: 30, relookMs: 100, pollMs: 40, ...options })
  stops.push(subscribe(topic, after, (data, cursor) => seen.push({ data, cursor })))
  return seen
}

describe('the topic of a place', () => {
  it('says when a record appears under the work directory, once for a burst of writes', async () => {
    const seen = subscribed('files.work', undefined, { debounceMs: 150 })
    await settle(seen)
    await mkdir(join(dir, 'work', 'pipelines', 'exec-1'))
    await writeFile(join(dir, 'work', 'pipelines', 'exec-1', 'execution.json'), '{}')
    await writeFile(join(dir, 'work', 'pipelines', 'exec-1', 'events.jsonl'), '')
    await until(() => seen.length > 0)
    await sleep(250)
    expect(seen).toEqual([{ data: {}, cursor: undefined }])
  })

  it('says when a note changes in the vault, and nothing of the git folder', async () => {
    await mkdir(join(dir, 'vault', '.git'), { recursive: true })
    const seen = subscribed('files.vault')
    await settle(seen)
    await writeFile(join(dir, 'vault', '.git', 'HEAD'), 'x')
    await sleep(200)
    expect(seen).toHaveLength(0)
    await writeFile(join(dir, 'vault', 'a.md'), '# a')
    await until(() => seen.length > 0)
  })

  it('takes up a folder that is made after the subscription, and tells that it is there', async () => {
    const seen = subscribed('files.vault')
    await sleep(150)
    expect(seen).toHaveLength(0)
    await mkdir(join(dir, 'vault'))
    await until(() => seen.length > 0)
  })

  it('stops telling when it is ended', async () => {
    const seen: unknown[] = []
    const subscribe = createTopics({ context, debounceMs: 30, relookMs: 100 })
    const stop = subscribe('files.work', undefined, (data) => seen.push(data))
    await settle(seen)
    stop()
    await writeFile(join(dir, 'work', 'pipelines', 'a'), 'x')
    await sleep(200)
    expect(seen).toEqual([])
  })
})

describe('the topic of a run', () => {
  let socket: Server
  const asked: unknown[] = []

  async function listening(events: { sequence: number }[]) {
    const id = 'exec-9'
    await mkdir(join(dir, 'work', 'pipelines', id), { recursive: true })
    socket = createServer((connection) => {
      connection.on('data', (chunk) => {
        const request = JSON.parse(String(chunk)) as { after?: number }
        asked.push(request)
        const fresh = events.filter((e) => e.sequence > (request.after ?? -1))
        connection.end(JSON.stringify({ ok: true, result: fresh }) + '\n')
      })
    })
    // Where a run would listen: in the record folder, or in the short folder
    // when the temporary directory makes that path too long for a socket.
    const path = socketPath(join(dir, 'work', 'pipelines'), id, process.platform)
    if (dirname(path) === shortSocketFolder(process.getuid?.() ?? 0)) {
      await mkdir(dirname(path), { recursive: true, mode: 0o700 })
    }
    await new Promise<void>((resolve) => socket.listen(path, resolve))
  }

  afterEach(() => {
    socket.close()
    asked.length = 0
  })

  it('gives the events of the run with their sequence as cursor, from the cursor it is given', async () => {
    await listening([{ sequence: 1 }, { sequence: 2 }, { sequence: 3 }])
    const seen = subscribed('run.exec-9', 1)
    await until(() => seen.length >= 2)
    expect(seen.map((e) => e.cursor)).toEqual([2, 3])
    expect(asked[0]).toEqual({ command: 'events', after: 1 })
  })

  it('asks for what follows the last event it gave', async () => {
    await listening([{ sequence: 0 }, { sequence: 1 }])
    const seen = subscribed('run.exec-9')
    await until(() => seen.length >= 2)
    await until(() => asked.length >= 2)
    expect(asked[0]).toEqual({ command: 'events' })
    expect(asked[1]).toEqual({ command: 'events', after: 1 })
    expect(seen.map((e) => e.cursor)).toEqual([0, 1])
  })

  it('goes on quietly while the run is not listening', async () => {
    socket = createServer()
    const seen = subscribed('run.exec-none')
    await sleep(200)
    expect(seen).toEqual([])
  })
})

describe('the topic of an agent run', () => {
  it('replays the lines published before the subscription and gives the ones after, with their index as cursor', async () => {
    const handle = context.noteRuns.start('abc_1')
    handle.publish('one')
    const seen = subscribed('note-run.abc_1')
    expect(seen).toEqual([{ data: { line: 'one' }, cursor: 0 }])
    handle.publish('two')
    expect(seen.at(-1)).toEqual({ data: { line: 'two' }, cursor: 1 })
    const later = subscribed('note-run.abc_1', 0)
    expect(later).toEqual([{ data: { line: 'two' }, cursor: 1 }])
    handle.finish()
  })
})

describe('the topic of usage', () => {
  it('reaches the usage subscriber, and its stop ends the subscription', async () => {
    const pushes: unknown[] = []
    let stopped = 0
    context.usage = {
      subscribe(push) {
        push({ readings: [] })
        pushes.push(push)
        return () => {
          stopped += 1
        }
      },
      nudge: () => undefined,
    }
    const seen = subscribed('usage')
    expect(pushes).toHaveLength(1)
    expect(seen).toEqual([{ data: { readings: [] }, cursor: undefined }])
    for (const stop of stops.splice(0)) stop()
    expect(stopped).toBe(1)
  })
})
