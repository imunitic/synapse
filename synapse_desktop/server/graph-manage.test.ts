import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { defaultConfig } from '../shared/calls.ts'
import type { AppConfig, CliResult } from '../shared/transport.ts'
import type { CliRun } from './cli.ts'
import {
  cleanGraphs,
  dropGraph,
  GraphActionRefused,
  planGraphClean,
  planGraphDrop,
} from './graph-manage.ts'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-manage-'))
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

const withRepo = (namespace: string): AppConfig => ({
  ...defaultConfig,
  graphRepos: { [namespace]: dir },
})

// Answers `namespace --repo` with the key, and a drop or clean with `output`.
function runner(
  key: string,
  output: CliResult = { code: 0, stdout: 'would-remove x\n', stderr: '' },
) {
  const seen: CliRun[] = []
  return {
    seen,
    run: (r: CliRun): Promise<CliResult> => {
      seen.push(r)
      return Promise.resolve(
        r.args[0] === 'namespace' ? { code: 0, stdout: `${key}\n`, stderr: '' } : output,
      )
    },
  }
}

const refusal = async (action: Promise<unknown>) =>
  action.then(
    () => null,
    (error: unknown) => error as GraphActionRefused,
  )

describe('deleting a graph', () => {
  it('is planned with a dry run in the saved repository, when it is on that namespace', async () => {
    const { run, seen } = runner('widget@main', {
      code: 0,
      stdout:
        'namespace: synapse/widget@main (2 nodes, 0 with ## Notes content)\nwould-remove synapse/widget@main\n',
      stderr: '',
    })
    const plan = await planGraphDrop(run, withRepo('widget@main'), 'widget@main')
    expect(plan.lines).toEqual([
      'namespace: synapse/widget@main (2 nodes, 0 with ## Notes content)',
      'would-remove synapse/widget@main',
    ])
    const wipe = seen.find((r) => r.args[0] === 'graph-wipe')
    expect(wipe).toMatchObject({ args: ['graph-wipe', '--dry-run'], cwd: dir })
  })

  it('is done without the dry run, in the same folder', async () => {
    const { run, seen } = runner('widget@main', {
      code: 0,
      stdout: 'removed synapse/widget@main\n',
      stderr: '',
    })
    expect(await dropGraph(run, withRepo('widget@main'), 'widget@main')).toEqual({
      output: 'removed synapse/widget@main',
    })
    expect(seen.find((r) => r.args[0] === 'graph-wipe')).toMatchObject({
      args: ['graph-wipe'],
      cwd: dir,
    })
  })

  it('is refused with no repository saved, or one that is gone', async () => {
    const { run, seen } = runner('widget@main')
    expect((await refusal(planGraphDrop(run, defaultConfig, 'widget@main')))?.message).toMatch(
      /no repository/,
    )
    const gone: AppConfig = { ...defaultConfig, graphRepos: { 'widget@main': join(dir, 'gone') } }
    expect((await refusal(dropGraph(run, gone, 'widget@main')))?.message).toMatch(/not a folder/)
    expect(seen).toHaveLength(0)
  })

  it('is refused when the saved folder is on another namespace, and nothing is run', async () => {
    const { run, seen } = runner('other@main')
    const refused = await refusal(dropGraph(run, withRepo('widget@main'), 'widget@main'))
    expect(refused?.message).toMatch(/on other@main, not widget@main/)
    expect(refused?.status).toBe(409)
    expect(seen.some((r) => r.args[0] === 'graph-wipe')).toBe(false)
  })

  it('says why a drop that failed did', async () => {
    const { run } = runner('widget@main', {
      code: 1,
      stdout: '',
      stderr: 'synapse-graph-wipe: no vault\n',
    })
    const refused = await refusal(dropGraph(run, withRepo('widget@main'), 'widget@main'))
    expect(refused).toMatchObject({ message: 'synapse-graph-wipe: no vault', status: 502 })
  })
})

describe('cleaning up the graphs of branches that are gone', () => {
  it('is planned and done in the saved repository, whatever branch it is on', async () => {
    const { run, seen } = runner('anything@else', {
      code: 0,
      stdout: 'nothing to clean\n',
      stderr: '',
    })
    const config = withRepo('widget@main')
    expect((await planGraphClean(run, config, 'widget@main')).lines).toEqual(['nothing to clean'])
    expect(await cleanGraphs(run, config, 'widget@main')).toEqual({ output: 'nothing to clean' })
    expect(seen.map((r) => [r.args, r.cwd])).toEqual([
      [['graph-clean', '--dry-run'], dir],
      [['graph-clean'], dir],
    ])
  })

  it('is refused with no repository saved', async () => {
    const { run } = runner('widget@main')
    expect((await refusal(cleanGraphs(run, defaultConfig, 'widget@main')))?.message).toMatch(
      /no repository/,
    )
  })
})
