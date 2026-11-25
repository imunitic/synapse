/// <reference types="vite/client" />
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { describe, expect, it, vi } from 'vitest'
import {
  type CodexChild,
  type CodexUsageDeps,
  mapCodexRateLimits,
  readCodexUsage,
  windowName,
} from './usage-codex.ts'

const fixtures = import.meta.glob<string>('../shared/examples/_usage-codex.json', {
  eager: true,
  query: '?raw',
  import: 'default',
})
// The fixture at `path`; a missing one fails the file at load rather than as a wrong figure.
function fixture(path: string): string {
  const text = fixtures[path]
  if (text === undefined) throw new Error(`no fixture at ${path}`)
  return text
}
const seen = JSON.parse(fixture('../shared/examples/_usage-codex.json')) as unknown
const now = new Date('2026-11-25T16:00:00.000Z')

describe('the rate limits of codex app-server', () => {
  it('maps the fixture to a 5h and a weekly window with ISO reset times', () => {
    expect(mapCodexRateLimits(seen, now)).toEqual({
      harness: 'Codex',
      kind: 'limit',
      windows: [
        { name: '5h', percent: 42, resetsAt: '2026-11-25T18:40:00.000Z', decides: true },
        { name: 'weekly', percent: 17, resetsAt: '2026-11-29T11:00:00.000Z', decides: true },
      ],
      spend: null,
      observedAt: '2026-11-25T16:00:00.000Z',
      state: 'ok',
      reason: null,
    })
  })

  it('names other durations in whole hours under 48 hours and whole days above', () => {
    expect([60, 300, 1440, 2880, 10080, 43200].map(windowName)).toEqual([
      '1h',
      '5h',
      '24h',
      '2d',
      'weekly',
      '30d',
    ])
  })

  it('is unavailable when rateLimits or a usedPercent is missing', () => {
    expect(mapCodexRateLimits({}, now)).toMatchObject({
      state: 'unavailable',
      reason: 'codex gave no rateLimits',
    })
    expect(
      mapCodexRateLimits({ rateLimits: { primary: { windowDurationMins: 300 } } }, now),
    ).toMatchObject({
      state: 'unavailable',
      reason: 'codex gave no usedPercent for its primary limit',
    })
  })
})

// A started `codex app-server` as a test has it: what the reader writes is kept, line by line,
// and `reply` answers on its stdout.
function fakeChild(): {
  child: CodexChild
  stdout: PassThrough
  written: unknown[]
  reply: (value: object) => void
} {
  const stdin = new PassThrough()
  const stdout = new PassThrough()
  const written: unknown[] = []
  let pending = ''
  stdin.on('data', (chunk: Buffer) => {
    pending += chunk.toString()
    const lines = pending.split('\n')
    pending = lines.pop() ?? ''
    for (const line of lines) written.push(JSON.parse(line))
  })
  const child = Object.assign(new EventEmitter(), { stdin, stdout, kill: vi.fn() })
  return { child, stdout, written, reply: (value) => stdout.write(`${JSON.stringify(value)}\n`) }
}

function deps(child: CodexChild | null, spawned: string[][] = []): CodexUsageDeps {
  return {
    findProgram: async () => (child === null ? null : '/bin/codex'),
    spawn: (program, args) => {
      spawned.push([program, ...args])
      if (child === null) throw new Error('no child')
      return child
    },
    clientVersion: '1.2.3',
    now: () => now,
  }
}

const settle = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 5))

describe('reading codex', () => {
  it('starts nothing when codex is not on PATH', async () => {
    const spawned: string[][] = []
    expect(await readCodexUsage(deps(null, spawned))).toEqual({
      harness: 'Codex',
      kind: 'limit',
      windows: [],
      spend: null,
      observedAt: null,
      state: 'not-installed',
      reason: 'codex is not on PATH',
    })
    expect(spawned).toEqual([])
  })

  it('writes the three messages in order and kills the process after the id-2 reply', async () => {
    const { child, written, reply } = fakeChild()
    const spawned: string[][] = []
    const reading = readCodexUsage(deps(child, spawned))
    await settle()
    expect(spawned).toEqual([['/bin/codex', 'app-server']])
    reply({ id: 1, result: { userAgent: 'codex/0.165.0' } })
    await settle()
    expect(child.kill).not.toHaveBeenCalled()
    reply({ method: 'account/rateLimits/updated', params: {} })
    reply({ id: 2, result: seen })
    expect(await reading).toEqual(mapCodexRateLimits(seen, now))
    expect(written).toEqual([
      {
        method: 'initialize',
        id: 1,
        params: { clientInfo: { name: 'synapse-desktop', version: '1.2.3' } },
      },
      { method: 'initialized' },
      { method: 'account/rateLimits/read', id: 2 },
    ])
    expect(child.kill).toHaveBeenCalledTimes(1)
  })

  it('maps an auth error to not-signed-in', async () => {
    const { child, reply } = fakeChild()
    const reading = readCodexUsage(deps(child))
    reply({ id: 1, result: {} })
    await settle()
    reply({ id: 2, error: { code: -32600, message: 'codex account authentication required' } })
    expect(await reading).toMatchObject({
      state: 'not-signed-in',
      reason: 'codex account authentication required',
    })
    expect(child.kill).toHaveBeenCalledTimes(1)
  })

  it('maps any other error to unavailable', async () => {
    const { child, reply } = fakeChild()
    const reading = readCodexUsage(deps(child))
    reply({ id: 1, error: { code: -32603, message: 'internal error' } })
    expect(await reading).toMatchObject({ state: 'unavailable', reason: 'internal error' })
  })

  it('is unavailable when the process ends before answering', async () => {
    const { child, stdout } = fakeChild()
    const reading = readCodexUsage(deps(child))
    stdout.end()
    expect(await reading).toMatchObject({
      state: 'unavailable',
      reason: 'codex app-server: exited before answering',
    })
  })
})
