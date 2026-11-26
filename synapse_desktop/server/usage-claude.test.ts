/// <reference types="vite/client" />
import { describe, expect, it } from 'vitest'
import {
  type ClaudeUsageDeps,
  parseClaudeUsage,
  readClaudeUsage,
  resetTime,
} from './usage-claude.ts'

// The fixtures as raw text, the way the host gets them on stdout.
const fixtures = import.meta.glob<string>('../shared/examples/_usage-claude*.json', {
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
const seen = fixture('../shared/examples/_usage-claude.json')
const noMatch = fixture('../shared/examples/_usage-claude-nomatch.json')

describe('the text of claude /usage', () => {
  it('gives every limit line of the seen output as a window', () => {
    const now = new Date('2026-11-25T16:00:00.000Z')
    expect(parseClaudeUsage(seen, now)).toEqual({
      harness: 'Claude',
      kind: 'limit',
      windows: [
        {
          name: 'Current session',
          percent: 13,
          resetsAt: '2026-11-25T18:09:00.000Z',
          decides: true,
        },
        {
          name: 'Current week (all models)',
          percent: 14,
          resetsAt: '2026-11-28T16:59:00.000Z',
          decides: true,
        },
        {
          name: 'Current week (Fable)',
          percent: 0,
          resetsAt: '2026-11-28T17:00:00.000Z',
          decides: false,
        },
      ],
      spend: null,
      observedAt: '2026-11-25T16:00:00.000Z',
      state: 'ok',
      reason: null,
    })
  })

  it('is unavailable, with its first line as the reason, when no line is a limit', () => {
    const reading = parseClaudeUsage(noMatch, new Date('2026-11-25T16:00:00.000Z'))
    expect(reading.state).toBe('unavailable')
    expect(reading.windows).toEqual([])
    expect(reading.observedAt).toBeNull()
    expect(reading.reason).toBe('Usage is only available for subscription plans.')
  })

  it('is unavailable when the output is not JSON or is an error', () => {
    const now = new Date('2026-11-25T16:00:00.000Z')
    expect(parseClaudeUsage('not json', now)).toMatchObject({
      state: 'unavailable',
      reason: 'claude /usage did not print JSON',
    })
    expect(
      parseClaudeUsage(JSON.stringify({ is_error: true, result: '\nNot logged in\n' }), now),
    ).toMatchObject({ state: 'unavailable', reason: 'Not logged in' })
  })

  it('keeps a window whose reset cannot be read, without a reset', () => {
    const json = JSON.stringify({
      result: 'Current session: 5% used · resets soon (Europe/Zagreb)',
    })
    const reading = parseClaudeUsage(json, new Date('2026-11-25T16:00:00.000Z'))
    expect(reading.state).toBe('ok')
    expect(reading.windows).toEqual([
      { name: 'Current session', percent: 5, resetsAt: null, decides: true },
    ])
  })
})

describe('a reset time of claude /usage', () => {
  it('takes the next year for a date already past this year', () => {
    expect(
      resetTime('Jan 2 at 9:00am', 'Europe/Zagreb', new Date('2026-12-30T00:00:00.000Z')),
    ).toBe('2027-01-02T08:00:00.000Z')
  })

  it('takes this year for a date still ahead', () => {
    expect(
      resetTime('Nov 25 at 7:09pm', 'Europe/Zagreb', new Date('2026-11-25T10:00:00.000Z')),
    ).toBe('2026-11-25T18:09:00.000Z')
  })

  it('reads a bare time as today or tomorrow, whichever is ahead', () => {
    const now = new Date('2026-11-25T10:00:00.000Z')
    expect(resetTime('5:59pm', 'Europe/Zagreb', now)).toBe('2026-11-25T16:59:00.000Z')
    expect(resetTime('9am', 'Europe/Zagreb', now)).toBe('2026-11-26T08:00:00.000Z')
  })

  it('gives nothing for an unknown zone or an unreadable text', () => {
    const now = new Date('2026-11-25T10:00:00.000Z')
    expect(resetTime('Nov 28 at 5pm', 'Nowhere/City', now)).toBeNull()
    expect(resetTime('in 3 hours', 'Europe/Zagreb', now)).toBeNull()
  })
})

describe('reading claude /usage', () => {
  const now = new Date('2026-11-25T16:00:00.000Z')
  type Run = ClaudeUsageDeps['run']
  const deps = (program: string | null, run: Run): ClaudeUsageDeps => ({
    findProgram: async () => program,
    run,
    workDir: async () => '/work',
    now: () => now,
  })

  it('starts nothing when claude is not on PATH', async () => {
    const calls: unknown[] = []
    const reading = await readClaudeUsage(
      deps(null, async (...args) => {
        calls.push(args)
        return { code: 0, stdout: seen, stderr: '' }
      }),
    )
    expect(reading).toEqual({
      harness: 'Claude',
      kind: 'limit',
      windows: [],
      spend: null,
      observedAt: null,
      state: 'not-installed',
      reason: 'claude is not on PATH',
    })
    expect(calls).toEqual([])
  })

  it('runs claude -p /usage in the work dir and reads what it prints', async () => {
    const calls: unknown[] = []
    const reading = await readClaudeUsage(
      deps('/bin/claude', async (...args) => {
        calls.push(args)
        return { code: 0, stdout: seen, stderr: '' }
      }),
    )
    expect(calls).toEqual([
      [
        '/bin/claude',
        ['-p', '/usage', '--output-format', 'json', '--no-session-persistence'],
        { cwd: '/work', timeoutMs: 30_000 },
      ],
    ])
    expect(reading).toEqual(parseClaudeUsage(seen, now))
  })

  it('gives unavailable for a timeout', async () => {
    const reading = await readClaudeUsage(
      deps('/bin/claude', async () => {
        throw new Error('timed out after 30 seconds')
      }),
    )
    expect(reading).toMatchObject({
      state: 'unavailable',
      windows: [],
      reason: 'claude /usage: timed out after 30 seconds',
    })
  })

  it('gives unavailable for a non-zero exit, with what it said', async () => {
    const reading = await readClaudeUsage(
      deps('/bin/claude', async () => ({ code: 2, stdout: '', stderr: '\nboom\n' })),
    )
    expect(reading).toMatchObject({
      state: 'unavailable',
      reason: 'claude /usage exited with code 2: boom',
    })
  })
})
