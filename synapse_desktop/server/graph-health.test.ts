import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { defaultConfig } from '../shared/calls.ts'
import type { CliResult } from '../shared/transport.ts'
import type { CliRun } from './cli.ts'
import { checkGraphRepo, graphHealth, parseFindings } from './graph-health.ts'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-health-'))
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

function runner(answer: (run: CliRun) => CliResult): {
  run: (r: CliRun) => Promise<CliResult>
  seen: CliRun[]
} {
  const seen: CliRun[] = []
  return {
    seen,
    run: (r) => {
      seen.push(r)
      return Promise.resolve(answer(r))
    },
  }
}

describe('the findings of a check', () => {
  it('are a node, a tab and a reason to a line, and none when nothing was printed', () => {
    expect(
      parseFindings(
        'Node A\tcontent changed in 2 of its files\n(repo)\t3 commits behind origin/main\n',
      ),
    ).toEqual([
      { node: 'Node A', reason: 'content changed in 2 of its files' },
      { node: '(repo)', reason: '3 commits behind origin/main' },
    ])
    expect(parseFindings('')).toEqual([])
    expect(parseFindings('A line with no tab\n')).toEqual([
      { node: 'A line with no tab', reason: '' },
    ])
  })
})

describe('the namespace of a repository folder', () => {
  it('is what synapse namespace says for the folder', async () => {
    const { run, seen } = runner(() => ({ code: 0, stdout: 'synapse@main\n', stderr: '' }))
    expect(await checkGraphRepo(run, defaultConfig, dir)).toEqual({
      key: 'synapse@main',
      error: null,
    })
    expect(seen[0]).toMatchObject({ binary: 'synapse', args: ['namespace', '--repo', dir] })
  })

  it('is none, with the reason, for a folder that is not on a branch', async () => {
    const { run } = runner(() => ({
      code: 1,
      stdout: '',
      stderr: 'synapse-namespace: not inside a git repo\n',
    }))
    expect(await checkGraphRepo(run, defaultConfig, dir)).toEqual({
      key: null,
      error: 'synapse-namespace: not inside a git repo',
    })
  })

  it('is none for a path that is not an absolute folder, without asking synapse', async () => {
    const { run, seen } = runner(() => ({ code: 0, stdout: 'x@y', stderr: '' }))
    expect((await checkGraphRepo(run, defaultConfig, 'relative/path')).error).toMatch(
      /not a folder/,
    )
    expect((await checkGraphRepo(run, defaultConfig, join(dir, 'missing'))).error).toMatch(
      /not a folder/,
    )
    expect(seen).toHaveLength(0)
  })
})

describe('the health of a graph', () => {
  it('is three checks of the namespace, each run on the repository', async () => {
    const { run, seen } = runner((r) => ({
      code: 0,
      stdout: r.args[3] === 'stale' ? 'Node A\ta file went\n' : '',
      stderr: '',
    }))
    const health = await graphHealth(run, defaultConfig, 'synapse@main', '/repo')
    expect(health.stale).toEqual({
      ok: true,
      findings: [{ node: 'Node A', reason: 'a file went' }],
    })
    expect(health.drift).toEqual({ ok: true, findings: [] })
    expect(health.grounding).toEqual({ ok: true, findings: [] })
    expect(seen.map((r) => r.args)).toEqual([
      ['query', '--namespace', 'synapse@main', 'stale'],
      ['query', '--namespace', 'synapse@main', 'drift'],
      ['query', '--namespace', 'synapse@main', 'grounding'],
    ])
    expect(seen.every((r) => r.env?.SYNAPSE_REPO_ROOT === '/repo')).toBe(true)
  })

  it('says why a check could not run, and never takes that for clean', async () => {
    const { run } = runner((r) =>
      r.args[3] === 'drift'
        ? { code: 1, stdout: '', stderr: "synapse-query: 'drift' needs the real files\n" }
        : { code: 0, stdout: '', stderr: '' },
    )
    const health = await graphHealth(run, defaultConfig, 'a@b', '/repo')
    expect(health.drift).toEqual({
      ok: false,
      error: "synapse-query: 'drift' needs the real files",
    })
    expect(health.stale.ok).toBe(true)
  })
})
