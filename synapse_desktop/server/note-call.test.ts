import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { CliResult } from '../shared/transport.ts'
import { CallError, handleCall, type Context } from './calls.ts'
import type { CliRun } from './cli.ts'
import type { NoteSessionRun } from './note-agent.ts'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-note-'))
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

// The settings as `synapse config list --format json` gives them, with the vault.
const settingsOf = (vault: string | null) =>
  JSON.stringify({
    settings: vault === null ? [] : [{ key: 'SYNAPSE_VAULT_DIR', value: vault }],
  })

// A vault whose listing is `listings` in turn, and a session that answers `answer`.
function contextFor(listings: string[], answer: CliResult, vault: string | null = '/the/vault') {
  const sessions: NoteSessionRun[] = []
  const listed: CliRun[] = []
  const context: Context = {
    environment: { env: { XDG_CONFIG_HOME: dir, MARK: 'x' }, home: dir },
    configFile: join(dir, 'config.json'),
    runCli: (run) => {
      if (run.args[0] === 'config') {
        return Promise.resolve({ code: 0, stdout: settingsOf(vault), stderr: '' })
      }
      listed.push(run)
      const stdout = listings.shift() ?? ''
      return Promise.resolve({ code: 0, stdout, stderr: '' })
    },
    runs: { start: () => Promise.reject(new Error('not used')), stop: () => undefined },
    agent: () => Promise.reject(new Error('not used')),
    noteSession: (run) => {
      sessions.push(run)
      return Promise.resolve(answer)
    },
  }
  return { context, sessions, listed }
}

const ok = (stdout: string): CliResult => ({ code: 0, stdout, stderr: '' })

const failure = async (action: Promise<unknown>) =>
  action.then(
    () => null,
    (error: unknown) => error as CallError,
  )

describe('the model of a note session', () => {
  const run = (context: Context, extra: object = {}) =>
    handleCall('createNote', { kind: 'note', prompt: 'x', ...extra }, context)

  it('is the one the request names, else the default of the harness that is used, else none', async () => {
    const { context, sessions } = contextFor(
      [
        'Index.md\n',
        'Index.md\na.md\n',
        'Index.md\n',
        'Index.md\na.md\n',
        'x\n',
        'x\ny.md\n',
        'x\n',
        'x\nz.md\n',
      ],
      ok('a.md\n'),
    )
    await handleCall('setConfig', { patch: { defaultModels: { Claude: 'sonnet' } } }, context)
    await run(context)
    await run(context, { model: 'opus' })
    await run(context, { harness: 'Codex' }).catch(() => null)
    expect(sessions.map((s) => [s.harness, s.model])).toEqual([
      ['Claude', 'sonnet'],
      ['Claude', 'opus'],
      ['Codex', undefined],
    ])
  })

  it('is left out of the session when there is none', async () => {
    const { context, sessions } = contextFor(['Index.md\n', 'Index.md\na.md\n'], ok('a.md\n'))
    await run(context)
    expect(sessions[0]).not.toHaveProperty('model')
  })
})

describe('writing a note with an agent', () => {
  it('runs the session with the prompt of the kind, and answers with the note that is new', async () => {
    const { context, sessions, listed } = contextFor(
      ['Index.md\n', 'Index.md\nresearch/Cache keys.md\n'],
      ok('written\nresearch/Cache keys.md\n'),
    )
    const answer = await handleCall(
      'createNote',
      { kind: 'design', prompt: 'Why keys are per branch' },
      context,
    )
    expect(answer).toEqual({ path: 'research/Cache keys.md' })
    expect(sessions).toHaveLength(1)
    expect(sessions[0]?.harness).toBe('Claude')
    expect(sessions[0]?.prompt).toContain('synapse-design-note skill')
    expect(sessions[0]?.prompt).toContain('Why keys are per branch')
    // The session gets the environment the app runs programs in.
    expect(sessions[0]?.env.MARK).toBe('x')
    // The vault is listed before the session and after it.
    expect(listed.map((run) => run.args)).toEqual([['vault-list'], ['vault-list']])
  })

  it('says why when the agent gave up, and when no note is new', async () => {
    const gave = contextFor(['Index.md\n', 'Index.md\n'], ok('FAILED: no project prefix\n'))
    const first = await failure(
      handleCall('createNote', { kind: 'task', prompt: 'Do it' }, gave.context),
    )
    expect(first).toMatchObject({ status: 502 })
    expect(first?.message).toContain('No note was written. no project prefix')

    const silent = contextFor(['Index.md\n', 'Index.md\n'], ok('I did something\n'))
    const second = await failure(
      handleCall('createNote', { kind: 'note', prompt: 'x' }, silent.context),
    )
    expect(second?.message).toContain('No note was written.')
    expect(second?.message).toContain('I did something')
  })

  it('is written by the default harness, and by the one the request names over it', async () => {
    const written = ['Index.md\n', 'Index.md\nresearch/A.md\n']
    const byDefault = contextFor([...written], ok('research/A.md'))
    await handleCall('setConfig', { patch: { defaultHarness: 'Codex' } }, byDefault.context)
    await handleCall('createNote', { kind: 'note', prompt: 'x' }, byDefault.context)
    expect(byDefault.sessions[0]?.harness).toBe('Codex')
    expect(byDefault.sessions[0]?.prompt).not.toContain('Only these commands work')

    const named = contextFor([...written], ok('research/A.md'))
    await handleCall('setConfig', { patch: { defaultHarness: 'Codex' } }, named.context)
    await handleCall(
      'createNote',
      { kind: 'note', prompt: 'x', harness: 'Opencode' },
      named.context,
    )
    expect(named.sessions[0]?.harness).toBe('Opencode')
    expect(named.sessions[0]?.prompt).toContain('Only these commands work')
  })

  it('lets the session write in the vault and the skills files that exist, and nowhere else', async () => {
    await mkdir(join(dir, '.config', 'synapse'), { recursive: true })
    const vault = join(dir, 'vault')
    await mkdir(vault)
    const { context, sessions } = contextFor(
      ['Index.md\n', 'Index.md\nresearch/A.md\n'],
      ok('research/A.md'),
      vault,
    )
    await handleCall('createNote', { kind: 'note', prompt: 'x' }, context)
    // The work folder does not exist here, so it is left out.
    expect(sessions[0]?.writable).toEqual([vault, join(dir, '.config', 'synapse')])
  })

  it('tells a task note the projects there are, or the one it was given', async () => {
    // The test's environment has the folder as XDG_CONFIG_HOME.
    await mkdir(join(dir, 'synapse'), { recursive: true })
    await writeFile(join(dir, 'synapse', 'synapse-projects.conf'), '# mine\nsynapse=sb\neon=ecs\n')
    const open = contextFor(['Index.md\n', 'Index.md\nresearch/A.md\n'], ok('research/A.md'))
    await handleCall('createNote', { kind: 'task', prompt: 'x' }, open.context)
    expect(open.sessions[0]?.prompt).toContain('as name=prefix: synapse=sb, eon=ecs')

    const given = contextFor(['Index.md\n', 'Index.md\nresearch/A.md\n'], ok('research/A.md'))
    await handleCall('createNote', { kind: 'task', prompt: 'x', project: 'eon' }, given.context)
    expect(given.sessions[0]?.prompt).toContain(
      'The project of this note is eon, with the prefix ecs',
    )

    const unknown = contextFor([], ok(''))
    const refused = await failure(
      handleCall('createNote', { kind: 'task', prompt: 'x', project: 'nope' }, unknown.context),
    )
    expect(refused).toMatchObject({ status: 409 })
    expect(refused?.message).toContain('nope is not a project')
    expect(unknown.sessions).toEqual([])
  })

  it('lists the projects, adds one, and refuses one that is taken', async () => {
    const { context } = contextFor([], ok(''))
    // The test's environment has the folder as XDG_CONFIG_HOME, so that is where they are.
    const file = join(dir, 'synapse', 'synapse-projects.conf')
    expect(await handleCall('listProjects', {}, context)).toEqual({ projects: [], file })
    expect(await handleCall('addProject', { name: 'thing', prefix: 'tg' }, context)).toEqual({
      projects: [{ name: 'thing', prefix: 'tg' }],
      file,
    })
    expect(await handleCall('listProjects', {}, context)).toEqual({
      projects: [{ name: 'thing', prefix: 'tg' }],
      file,
    })
    const taken = await failure(
      handleCall('addProject', { name: 'thing', prefix: 'other' }, context),
    )
    expect(taken).toMatchObject({ status: 409 })
    const bad = await failure(handleCall('addProject', { name: 'No Good', prefix: 'tg2' }, context))
    expect(bad).toMatchObject({ status: 409 })
  })

  it('is refused, before anything is run, when no vault is set up', async () => {
    const { context, sessions, listed } = contextFor([], ok(''), null)
    const refused = await failure(handleCall('createNote', { kind: 'note', prompt: 'x' }, context))
    expect(refused).toMatchObject({ status: 409 })
    expect(refused?.message).toContain('no vault')
    expect(sessions).toEqual([])
    expect(listed).toEqual([])
  })

  it('refuses a kind it does not know and an empty description', async () => {
    const { context } = contextFor([], ok(''))
    expect(
      await failure(handleCall('createNote', { kind: 'essay', prompt: 'x' }, context)),
    ).toMatchObject({ status: 400 })
    expect(
      await failure(handleCall('createNote', { kind: 'note', prompt: '' }, context)),
    ).toMatchObject({ status: 400 })
  })
})
