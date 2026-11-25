/// <reference types="vite/client" />
import { describe, expect, it } from 'vitest'
import {
  majorVersion,
  mapOpencodeStats,
  type OpencodeUsageDeps,
  readOpencodeUsage,
} from './usage-opencode.ts'

// The fixture as raw text, the way the host gets it on stdout.
const fixtures = import.meta.glob<string>('../shared/examples/_usage-opencode.json', {
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
const stats = fixture('../shared/examples/_usage-opencode.json')
const now = new Date('2026-11-25T16:00:00.000Z')

type Output = { code: number; stdout: string; stderr: string }

// A machine with `opencode` where it says, answering `--version` with `version` and `stats` with
// `statsOutput`, keeping every call.
function machine(program: string | null, version: string, statsOutput: Output) {
  const calls: Array<{ program: string; args: string[]; cwd: string; timeoutMs: number }> = []
  const deps: OpencodeUsageDeps = {
    findProgram: async () => program,
    run: async (program, args, options) => {
      calls.push({ program, args, ...options })
      return args[0] === '--version' ? { code: 0, stdout: version, stderr: '' } : statsOutput
    },
    workDir: async () => '/work',
    now: () => now,
  }
  return { deps, calls }
}

describe('the output of opencode stats --json', () => {
  it('maps the fixture to its cost as spend today', () => {
    expect(mapOpencodeStats(stats, now)).toEqual({
      harness: 'Opencode',
      kind: 'spend',
      windows: [],
      spend: { amount: 1.42, period: 'today' },
      observedAt: '2026-11-25T16:00:00.000Z',
      state: 'ok',
      reason: null,
    })
  })

  it('is unavailable without the cost field or without JSON', () => {
    const noCost = JSON.stringify({ ...JSON.parse(stats), cost: undefined })
    expect(mapOpencodeStats(noCost, now)).toMatchObject({
      state: 'unavailable',
      spend: null,
      observedAt: null,
      reason: 'opencode stats gave no cost',
    })
    expect(mapOpencodeStats('not json', now)).toMatchObject({
      state: 'unavailable',
      reason: 'opencode stats did not print JSON',
    })
  })

  it('reads the major version from what --version prints', () => {
    expect(majorVersion('2.0.0\n')).toBe(2)
    expect(majorVersion('opencode 1.4.2')).toBe(1)
    expect(majorVersion('dev')).toBeNull()
  })
})

describe('reading opencode', () => {
  it('starts nothing when it is not on PATH', async () => {
    const { deps, calls } = machine(null, '2.0.0', { code: 0, stdout: stats, stderr: '' })
    expect(await readOpencodeUsage(deps)).toMatchObject({
      harness: 'Opencode',
      state: 'not-installed',
      reason: 'opencode is not on PATH',
    })
    expect(calls).toEqual([])
  })

  it('runs stats --days 0 --json for version 2.0.0 and reads its cost', async () => {
    const { deps, calls } = machine('/bin/opencode', '2.0.0\n', {
      code: 0,
      stdout: stats,
      stderr: '',
    })
    expect(await readOpencodeUsage(deps)).toEqual(mapOpencodeStats(stats, now))
    expect(calls).toEqual([
      { program: '/bin/opencode', args: ['--version'], cwd: '/work', timeoutMs: 15_000 },
      {
        program: '/bin/opencode',
        args: ['stats', '--days', '0', '--json'],
        cwd: '/work',
        timeoutMs: 15_000,
      },
    ])
  })

  it('is unavailable for version 1.4.2 without running stats', async () => {
    const { deps, calls } = machine('/bin/opencode', '1.4.2\n', {
      code: 0,
      stdout: stats,
      stderr: '',
    })
    expect(await readOpencodeUsage(deps)).toMatchObject({
      state: 'unavailable',
      reason: 'opencode 1.x has no stats --json; update to 2.x',
    })
    expect(calls.map((call) => call.args)).toEqual([['--version']])
  })

  it('is unavailable when stats fails', async () => {
    const { deps } = machine('/bin/opencode', '2.1.2', { code: 1, stdout: '', stderr: '\nboom\n' })
    expect(await readOpencodeUsage(deps)).toMatchObject({
      state: 'unavailable',
      reason: 'opencode stats exited with code 1: boom',
    })
  })
})
