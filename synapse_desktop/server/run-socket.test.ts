import { mkdtemp, rm } from 'node:fs/promises'
import { createServer, type Server } from 'node:net'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { askRun, NotListening, socketPath } from './run-socket.ts'

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
