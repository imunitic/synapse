import { chmodSync, existsSync, mkdirSync, realpathSync, symlinkSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { createServer, type Server } from 'node:net'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  askRun,
  fnv1a64Hex,
  isPrivateFolder,
  MAX_SOCKET_PATH,
  NotListening,
  socketEndpoint,
  socketPath,
} from './run-socket.ts'

// A Unix socket path is limited to about 100 characters, which the system
// temporary directory of macOS can use up on its own.
let dir: string
let server: Server | null

beforeEach(async () => {
  dir = await mkdtemp('/tmp/sd-')
  server = null
})

afterEach(async () => {
  if (server) await new Promise((resolve) => server?.close(resolve))
  await rm(dir, { recursive: true, force: true })
})

function listen(onRequest: (line: string) => string | null): Promise<string> {
  const path = join(dir, 'run.sock')
  server = createServer((connection) => {
    let text = ''
    connection.on('data', (chunk) => {
      text += chunk.toString()
      if (!text.includes('\n')) return
      const reply = onRequest(text.trim())
      if (reply !== null) connection.end(reply)
    })
  })
  return new Promise((resolve) => server?.listen(path, () => resolve(path)))
}

describe.skipIf(process.platform === 'win32')('askRun', () => {
  it('sends the request as one JSON line and returns the answer', async () => {
    let seen = ''
    const path = await listen((line) => {
      seen = line
      return JSON.stringify({ ok: true, result: { status: 'running' } })
    })
    const answer = await askRun(path, { command: 'info' })
    expect(JSON.parse(seen)).toEqual({ command: 'info' })
    expect(answer).toEqual({ ok: true, result: { status: 'running' } })
  })

  it('returns an error answer as it is', async () => {
    const path = await listen(() => JSON.stringify({ ok: false, error: 'unknown command' }))
    expect(await askRun(path, { command: 'info' })).toEqual({ ok: false, error: 'unknown command' })
  })

  it('rejects with NotListening when no run listens on the path', async () => {
    await expect(askRun(join(dir, 'gone.sock'), { command: 'info' })).rejects.toBeInstanceOf(
      NotListening,
    )
  })

  it('rejects, and not with NotListening, when the answer is not JSON', async () => {
    const path = await listen(() => 'not json')
    const failure = await askRun(path, { command: 'info' }).catch((error: unknown) => error)
    expect(failure).toBeInstanceOf(Error)
    expect(failure).not.toBeInstanceOf(NotListening)
  })
})

// The same values as synapse-pipeline's Socket_Paths tests and the Rust
// host's: the first two are the published FNV-1a 64 test values, the third the
// example the three share.
describe('fnv1a64Hex', () => {
  it('is FNV-1a 64', () => {
    expect(fnv1a64Hex('')).toBe('cbf29ce484222325')
    expect(fnv1a64Hex('a')).toBe('af63dc4c8601ec8c')
    expect(fnv1a64Hex('/Users/example/.cache/synapse/work/pipelines/probe1')).toBe(
      '04096b4c0fbf6a6c',
    )
  })
})

describe('socketEndpoint', () => {
  const name = 'execution.sock'
  it('stays in the record folder while the path fits', () => {
    const longest = '/' + 'r'.repeat(MAX_SOCKET_PATH - 1 - name.length - 1)
    expect(socketEndpoint(longest, 501)).toBe(`${longest}/${name}`)
  })

  it('goes to the short folder when the path is one byte over', () => {
    const over = '/' + 'r'.repeat(MAX_SOCKET_PATH - name.length - 1)
    const got = socketEndpoint(over, 501)
    expect(got).toBe(`/tmp/synapse-pipeline-501/${fnv1a64Hex(over)}.sock`)
    expect(got.length).toBeLessThanOrEqual(MAX_SOCKET_PATH)
  })
})

describe.skipIf(process.platform === 'win32')('socketPath on disk', () => {
  const uid = process.getuid?.() ?? 0

  it('hashes the record folder as it is on disk', () => {
    const base = realpathSync.native(dir)
    const deep = join(base, 'd'.repeat(90), 'pipelines')
    mkdirSync(join(deep, 'Exec-Case'), { recursive: true })
    const expected = socketEndpoint(join(deep, 'Exec-Case'), uid)
    expect(socketPath(deep, 'Exec-Case', 'darwin')).toBe(expected)
    // On a file system that ignores case, another spelling is the same folder.
    if (existsSync(join(deep, 'exec-case'))) {
      expect(socketPath(deep, 'exec-case', 'darwin')).toBe(expected)
    }
    symlinkSync(deep, join(base, 'link'))
    expect(socketPath(join(base, 'link'), 'Exec-Case', 'darwin')).toBe(expected)
  })

  it('takes only a folder of the user own, with no access for others, as private', () => {
    const own = join(dir, 'own')
    mkdirSync(own, { mode: 0o700 })
    chmodSync(own, 0o700)
    expect(isPrivateFolder(own, uid)).toBe(true)
    expect(isPrivateFolder(own, uid + 1)).toBe(false)
    chmodSync(own, 0o755)
    expect(isPrivateFolder(own, uid)).toBe(false)
    chmodSync(own, 0o700)
    symlinkSync(own, join(dir, 'link'))
    expect(isPrivateFolder(join(dir, 'link'), uid)).toBe(false)
    writeFileSync(join(dir, 'file'), '')
    expect(isPrivateFolder(join(dir, 'file'), uid)).toBe(false)
    expect(isPrivateFolder(join(dir, 'missing'), uid)).toBe(false)
  })
})

describe('socketPath', () => {
  it('is execution.sock in the record directory, or a named pipe on Windows', () => {
    expect(socketPath('/w/pipelines', 'exec-1', 'darwin')).toBe(
      '/w/pipelines/exec-1/execution.sock',
    )
    expect(socketPath('/w/pipelines', 'exec-1', 'win32')).toBe(
      '\\\\.\\pipe\\synapse-pipeline-exec-1',
    )
  })
})
