import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Params, Result } from '../shared/messages.ts'
import { handleMessage, type CallMessage, type Context } from './calls.ts'
import type { CliRun } from './cli.ts'
import { NotStartedHere, RunNotStarted } from './runs.ts'
import { HostError } from '../shared/dispatch.ts'
import { createNoteRuns } from './note-runs.ts'

let dir: string
let context: Context
let cliCalls: CliRun[]
let cliResult: { code: number; stdout: string; stderr: string }

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-calls-'))
  cliCalls = []
  cliResult = { code: 0, stdout: 'ok', stderr: '' }
  context = {
    environment: { env: { XDG_CONFIG_HOME: join(dir, 'xdg') }, home: dir },
    configFile: join(dir, 'config.json'),
    runs: {
      start: () => Promise.reject(new RunNotStarted('stub')),
      stop: () => {
        throw new NotStartedHere('stub')
      },
    },
    agent: () => Promise.reject(new Error('not used')),
    noteSession: () => Promise.reject(new Error('not used')),
    noteRuns: createNoteRuns(),
    runCli: (run) => {
      cliCalls.push(run)
      return Promise.resolve(cliResult)
    },
  }
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

const ask = <N extends CallMessage>(name: N, params: Params<N>): Promise<Result<N>> =>
  handleMessage(name, params, context)

// What a failing request is: a HostError, with the status the host gives its code.
async function failure(request: Promise<unknown>): Promise<HostError> {
  const error = await request.then(
    () => null,
    (e: unknown) => e,
  )
  expect(error).toBeInstanceOf(HostError)
  return error as HostError
}

describe('the messages of the host', () => {
  it('answers config.get with the default configuration and the paths', async () => {
    const answer = await ask('config.get', {})
    expect(answer.config).toEqual({
      // Nothing names a work directory, so it is the default in the home.
      workDir: join(dir, '.cache', 'synapse', 'work'),
      definitionPaths: [],
      defaultHarness: null,
      env: {},
      recentVaults: [],
      terminalFolder: null,
      defaultModels: {},
      defaultEfforts: {},
      graphRepos: {},
    })
  })

  it('reads a graph against the repository saved for it, and says when none is', async () => {
    const none = await failure(ask('graph.health', { namespace: 'synapse@main' }))
    expect(none.code).toBe('conflict')
    expect(none.message).toMatch(/no repository/)

    await ask('config.set', { patch: { graphRepos: { 'synapse@main': dir } } })
    cliResult = { code: 0, stdout: 'Node A\tchanged\n', stderr: '' }
    const health = await ask('graph.health', { namespace: 'synapse@main' })
    expect(health.stale).toMatchObject({
      ok: true,
      findings: [{ node: 'Node A', reason: 'changed' }],
    })
    expect(cliCalls.at(-1)?.env?.SYNAPSE_REPO_ROOT).toBe(dir)

    await ask('config.set', { patch: { graphRepos: { 'synapse@main': join(dir, 'gone') } } })
    expect((await failure(ask('graph.health', { namespace: 'synapse@main' }))).code).toBe(
      'conflict',
    )
    expect((await failure(ask('graph.health', { namespace: '../x@y' }))).code).toBe('bad_request')
  })

  it('plans and does a drop in the repository saved for the graph, and refuses without one', async () => {
    const plan = { action: 'plan', what: 'drop', namespace: 'a@main' } as const
    const drop = { action: 'apply', what: 'drop', namespace: 'a@main' } as const
    expect((await failure(ask('graph.manage', plan))).code).toBe('conflict')
    expect((await failure(ask('graph.manage', { ...drop, namespace: '../x@y' }))).code).toBe(
      'bad_request',
    )

    await ask('config.set', { patch: { graphRepos: { 'a@main': dir } } })
    cliResult = { code: 0, stdout: 'a@main\n', stderr: '' }
    await ask('graph.manage', plan)
    expect(cliCalls.find((c) => c.args[0] === 'graph-wipe')).toMatchObject({
      args: ['graph-wipe', '--dry-run'],
      cwd: dir,
    })
    // The folder is on another branch: nothing is dropped.
    cliResult = { code: 0, stdout: 'b@main\n', stderr: '' }
    const wrong = await failure(ask('graph.manage', drop))
    expect(wrong.code).toBe('conflict')
    expect(wrong.message).toMatch(/would delete another graph/)
  })

  it('asks synapse which namespace a folder is on', async () => {
    cliResult = { code: 0, stdout: 'synapse@main\n', stderr: '' }
    const answer = await ask('graph.repo', { action: 'check', path: dir })
    expect(answer).toEqual({ action: 'check', check: { key: 'synapse@main', error: null } })
    expect(cliCalls.at(-1)?.args).toEqual(['namespace', '--repo', dir])
  })

  it('takes ~ for the home folder in a path that is typed, and keeps the folder that makes', async () => {
    await mkdir(join(dir, 'code'), { recursive: true })
    cliResult = { code: 0, stdout: 'synapse@main\n', stderr: '' }
    const answer = await ask('graph.repo', { action: 'check', path: '~/code' })
    expect(answer).toEqual({ action: 'check', check: { key: 'synapse@main', error: null } })
    expect(cliCalls.at(-1)?.args).toEqual(['namespace', '--repo', join(dir, 'code')])

    // What is saved is the folder, so that a program that is handed it can use it.
    await ask('config.set', {
      patch: {
        workDir: '~/work',
        definitionPaths: ['~/defs'],
        terminalFolder: '~',
        graphRepos: { 'a@main': '~/code' },
      },
    })
    expect((await ask('config.get', {})).config).toMatchObject({
      workDir: join(dir, 'work'),
      definitionPaths: [join(dir, 'defs')],
      terminalFolder: dir,
      graphRepos: { 'a@main': join(dir, 'code') },
    })
  })

  it('says what each harness has installed', async () => {
    const answer = await ask('integrations', {})
    expect(answer.harnesses.map((h) => h.harness)).toEqual(['Claude', 'Codex', 'Opencode'])
  })

  it('keeps what config.set stores', async () => {
    await ask('config.set', { patch: { workDir: '/w', defaultHarness: 'Codex' } })
    expect((await ask('config.get', {})).config).toEqual({
      workDir: '/w',
      definitionPaths: [],
      defaultHarness: 'Codex',
      env: {},
      recentVaults: [],
      terminalFolder: null,
      defaultModels: {},
      defaultEfforts: {},
      graphRepos: {},
    })
  })

  it('an effort the harness does not offer is refused', async () => {
    const refused = await failure(
      ask('agent.run', {
        kind: 'run-input',
        pipeline: 'P',
        prompt: 'x',
        harness: 'Claude',
        effort: 'minimal',
      }),
    )
    expect(refused.code).toBe('bad_request')
    expect(refused.message).toBe("Claude does not offer effort 'minimal'")
  })

  it('an OpenCode variant without a model is refused', async () => {
    const refused = await failure(
      ask('agent.run', {
        kind: 'run-input',
        pipeline: 'P',
        prompt: 'x',
        harness: 'Opencode',
        effort: 'high',
      }),
    )
    expect(refused.code).toBe('bad_request')
    expect(refused.message).toBe('an OpenCode variant needs a model')
  })

  it('refuses parameters that are not those of the message', async () => {
    expect((await failure(handleMessage('fs.read', { path: 5 }, context))).code).toBe('bad_request')
  })

  it('reads a definition file and refuses any other file', async () => {
    const definitions = join(dir, 'xdg', 'synapse-pipeline')
    await mkdir(definitions, { recursive: true })
    await writeFile(join(definitions, 'P.synapse'), 'Pipeline P {}')
    await writeFile(join(dir, 'private.txt'), 'secret')

    expect(await ask('fs.read', { path: join(definitions, 'P.synapse') })).toEqual({
      text: 'Pipeline P {}',
    })
    expect((await failure(ask('fs.read', { path: join(dir, 'private.txt') }))).code).toBe(
      'forbidden',
    )
    expect((await failure(ask('fs.list', { path: dir }))).code).toBe('forbidden')
  })

  it('runs an allowed CLI subcommand and refuses the others without running them', async () => {
    const ok = await ask('cli', {
      binary: 'synapse-pipeline',
      args: ['show', 'P', '--format', 'json'],
    })
    expect(ok).toEqual({ code: 0, stdout: 'ok', stderr: '' })
    expect(cliCalls).toHaveLength(1)

    const refused = await failure(ask('cli', { binary: 'synapse-pipeline', args: ['run', 'P'] }))
    expect(refused.code).toBe('bad_request')
    expect(cliCalls).toHaveLength(1)
  })

  it('lists only the directories that exist', async () => {
    const definitions = join(dir, 'xdg', 'synapse-pipeline')
    await mkdir(definitions, { recursive: true })
    await ask('config.set', {
      patch: { workDir: join(dir, 'work'), definitionPaths: [join(dir, 'missing')] },
    })

    expect((await ask('config.get', {})).paths).toEqual({
      definitionDirs: [definitions],
      recordsDir: null,
    })

    await mkdir(join(dir, 'work', 'pipelines'), { recursive: true })
    expect((await ask('config.get', {})).paths).toMatchObject({
      recordsDir: join(dir, 'work', 'pipelines'),
    })
  })

  it('refuses a run id that would leave the records directory', async () => {
    await ask('config.set', { patch: { workDir: join(dir, 'work') } })
    const error = await failure(
      handleMessage('run.ask', { executionId: '../x', request: { command: 'info' } }, context),
    )
    expect(error.code).toBe('bad_request')
  })

  it('reports a run that is not listening, in the work directory there is by default', async () => {
    const info = { executionId: 'exec-1', request: { command: 'info' } } as const
    expect((await failure(ask('run.ask', info))).code).toBe('not_found')

    await ask('config.set', { patch: { workDir: join(dir, 'work') } })
    expect((await failure(ask('run.ask', info))).code).toBe('not_found')
  })
})
