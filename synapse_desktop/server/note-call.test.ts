import { mkdir, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { CliResult } from '../shared/transport.ts'
import { handleMessage, type Context } from './calls.ts'
import type { CliRun } from './cli.ts'
import type { NoteSessionRun } from './note-agent.ts'
import { createNoteRuns } from './note-runs.ts'
import { HostError } from '../shared/dispatch.ts'

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

interface Pair {
  name: string
  prefix: string
}

// What `synapse projects` answers, over the pairs it holds: the listing, and the refusals of an add
// that matter to the app, which are the program's own rules.
function projectsProgram(pairs: Pair[], file: string, run: CliRun): CliResult {
  const refuse = (why: string): CliResult => ({
    code: 1,
    stdout: '',
    stderr: `synapse-projects: ${why}\n`,
  })
  if (run.args[1] === 'add') {
    const [, , name = '', prefix = ''] = run.args
    const sameName = pairs.find((p) => p.name === name)
    if (sameName !== undefined) {
      return refuse(`${name} is already a project, with the prefix ${sameName.prefix}.`)
    }
    const samePrefix = pairs.find((p) => p.prefix === prefix)
    if (samePrefix !== undefined) {
      return refuse(`The prefix ${prefix} is already the prefix of ${samePrefix.name}.`)
    }
    if (!/^[a-z0-9][a-z0-9._-]*$/.test(name)) return refuse('A project name is lower case letters.')
    pairs.push({ name, prefix })
    return { code: 0, stdout: `${file}\n`, stderr: '' }
  }
  return {
    code: 0,
    stdout: JSON.stringify({ format: 'synapse-projects/v1', file, projects: pairs }),
    stderr: '',
  }
}

// A vault whose listing is `listings` in turn, and a session that answers `answer`.
function contextFor(
  listings: string[],
  answer: CliResult,
  vault: string | null = '/the/vault',
  pairs: Pair[] = [],
) {
  const sessions: NoteSessionRun[] = []
  const listed: CliRun[] = []
  const context: Context = {
    environment: { env: { XDG_CONFIG_HOME: dir, MARK: 'x' }, home: dir },
    configFile: join(dir, 'config.json'),
    runCli: (run) => {
      if (run.args[0] === 'config') {
        return Promise.resolve({ code: 0, stdout: settingsOf(vault), stderr: '' })
      }
      if (run.args[0] === 'projects') {
        return Promise.resolve(
          projectsProgram(pairs, join(dir, 'synapse', 'synapse-projects.conf'), run),
        )
      }
      listed.push(run)
      const stdout = listings.shift() ?? ''
      return Promise.resolve({ code: 0, stdout, stderr: '' })
    },
    runs: { start: () => Promise.reject(new Error('not used')), stop: () => undefined },
    agent: () => Promise.reject(new Error('not used')),
    noteRuns: createNoteRuns(),
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
    (error: unknown) => error as HostError,
  )

describe('the model of a note session', () => {
  const run = (context: Context, extra: object = {}) =>
    handleMessage('agent.run', { kind: 'note', what: 'note', prompt: 'x', ...extra }, context)

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
    await handleMessage('config.set', { patch: { defaultModels: { Claude: 'sonnet' } } }, context)
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
    const answer = await handleMessage(
      'agent.run',
      { kind: 'note', what: 'design', prompt: 'Why keys are per branch' },
      context,
    )
    expect(answer).toEqual({ kind: 'note', path: 'research/Cache keys.md' })
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
      handleMessage('agent.run', { kind: 'note', what: 'task', prompt: 'Do it' }, gave.context),
    )
    expect(first).toMatchObject({ code: 'unavailable' })
    expect(first?.message).toContain('No note was written. no project prefix')

    const silent = contextFor(['Index.md\n', 'Index.md\n'], ok('I did something\n'))
    const second = await failure(
      handleMessage('agent.run', { kind: 'note', what: 'note', prompt: 'x' }, silent.context),
    )
    expect(second?.message).toContain('No note was written.')
    expect(second?.message).toContain('I did something')
  })

  it('is written by the default harness, and by the one the request names over it', async () => {
    const written = ['Index.md\n', 'Index.md\nresearch/A.md\n']
    const byDefault = contextFor([...written], ok('research/A.md'))
    await handleMessage('config.set', { patch: { defaultHarness: 'Codex' } }, byDefault.context)
    await handleMessage('agent.run', { kind: 'note', what: 'note', prompt: 'x' }, byDefault.context)
    expect(byDefault.sessions[0]?.harness).toBe('Codex')
    expect(byDefault.sessions[0]?.prompt).not.toContain('Only these commands work')

    const named = contextFor([...written], ok('research/A.md'))
    await handleMessage('config.set', { patch: { defaultHarness: 'Codex' } }, named.context)
    await handleMessage(
      'agent.run',
      { kind: 'note', what: 'note', prompt: 'x', harness: 'Opencode' },
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
    await handleMessage('agent.run', { kind: 'note', what: 'note', prompt: 'x' }, context)
    // The work folder does not exist here, so it is left out.
    expect(sessions[0]?.writable).toEqual([vault, join(dir, '.config', 'synapse')])
  })

  it('tells a task note the projects there are, or the one it was given', async () => {
    const known = [
      { name: 'synapse', prefix: 'sb' },
      { name: 'eon', prefix: 'ecs' },
    ]
    const open = contextFor(
      ['Index.md\n', 'Index.md\nresearch/A.md\n'],
      ok('research/A.md'),
      '/the/vault',
      known,
    )
    await handleMessage('agent.run', { kind: 'note', what: 'task', prompt: 'x' }, open.context)
    expect(open.sessions[0]?.prompt).toContain('as name=prefix: synapse=sb, eon=ecs')

    const given = contextFor(
      ['Index.md\n', 'Index.md\nresearch/A.md\n'],
      ok('research/A.md'),
      '/the/vault',
      known,
    )
    await handleMessage(
      'agent.run',
      { kind: 'note', what: 'task', prompt: 'x', project: 'eon' },
      given.context,
    )
    expect(given.sessions[0]?.prompt).toContain(
      'The project of this note is eon, with the prefix ecs',
    )

    const unknown = contextFor([], ok(''), '/the/vault', known)
    const refused = await failure(
      handleMessage(
        'agent.run',
        { kind: 'note', what: 'task', prompt: 'x', project: 'nope' },
        unknown.context,
      ),
    )
    expect(refused).toMatchObject({ code: 'conflict' })
    expect(refused?.message).toContain('nope is not a project')
    expect(unknown.sessions).toEqual([])
  })

  it('lists the projects, adds one, and refuses one that is taken', async () => {
    const { context } = contextFor([], ok(''))
    // The file is where the program says it is.
    const file = join(dir, 'synapse', 'synapse-projects.conf')
    expect(await handleMessage('registry.list', { kind: 'projects' }, context)).toEqual({
      kind: 'projects',
      list: { projects: [], file },
    })
    expect(
      await handleMessage(
        'registry.add',
        { kind: 'projects', name: 'thing', prefix: 'tg' },
        context,
      ),
    ).toEqual({
      kind: 'projects',
      list: { projects: [{ name: 'thing', prefix: 'tg' }], file },
    })
    expect(await handleMessage('registry.list', { kind: 'projects' }, context)).toEqual({
      kind: 'projects',
      list: { projects: [{ name: 'thing', prefix: 'tg' }], file },
    })
    const taken = await failure(
      handleMessage('registry.add', { kind: 'projects', name: 'thing', prefix: 'other' }, context),
    )
    expect(taken).toMatchObject({ code: 'conflict' })
    const bad = await failure(
      handleMessage('registry.add', { kind: 'projects', name: 'No Good', prefix: 'tg2' }, context),
    )
    expect(bad).toMatchObject({ code: 'conflict' })
    // What the program said is what is told, without its own name in front.
    expect(taken?.message).toBe('thing is already a project, with the prefix tg.')
  })

  it('says so when synapse has no projects command, as an older release has not', async () => {
    const { context } = contextFor([], ok(''))
    const run = context.runCli
    context.runCli = (request) =>
      request.args[0] === 'projects'
        ? Promise.resolve({
            code: 1,
            stdout: '',
            stderr: "synapse: unknown subcommand 'projects'\n",
          })
        : run(request)
    const refused = await failure(handleMessage('registry.list', { kind: 'projects' }, context))
    expect(refused).toMatchObject({ code: 'unavailable' })
    expect(refused?.message).toContain("unknown subcommand 'projects'")
  })

  it('is refused, before anything is run, when no vault is set up', async () => {
    const { context, sessions, listed } = contextFor([], ok(''), null)
    const refused = await failure(
      handleMessage('agent.run', { kind: 'note', what: 'note', prompt: 'x' }, context),
    )
    expect(refused).toMatchObject({ code: 'conflict' })
    expect(refused?.message).toContain('no vault')
    expect(sessions).toEqual([])
    expect(listed).toEqual([])
  })

  it('refuses a kind it does not know and an empty description', async () => {
    const { context } = contextFor([], ok(''))
    expect(
      await failure(
        handleMessage('agent.run', { kind: 'note', what: 'essay', prompt: 'x' }, context),
      ),
    ).toMatchObject({ code: 'bad_request' })
    expect(
      await failure(
        handleMessage('agent.run', { kind: 'note', what: 'note', prompt: '' }, context),
      ),
    ).toMatchObject({ code: 'bad_request' })
  })
})

// A session that waits for its signal, the way a stopped harness ends, and answers code 143.
function waitingSession(
  context: Context,
  seen: NoteSessionRun[],
  after: () => void = () => undefined,
): void {
  context.noteSession = (run) => {
    seen.push(run)
    return new Promise((resolve) => {
      run.signal?.addEventListener('abort', () => {
        after()
        resolve({ code: 143, stdout: '', stderr: '' })
      })
    })
  }
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 10))

describe('a run that can be stopped', () => {
  it('gives the session a signal, ends it on agent.stop and is finished afterwards, for a new note', async () => {
    const { context, sessions } = contextFor(['Index.md\n', 'Index.md\n'], ok(''))
    waitingSession(context, sessions)
    const running = failure(
      handleMessage('agent.run', { kind: 'note', what: 'note', prompt: 'x', run: 'r1' }, context),
    )
    await tick()
    expect(sessions[0]?.signal?.aborted).toBe(false)
    await handleMessage('agent.stop', { run: 'r1' }, context)
    expect(sessions[0]?.signal?.aborted).toBe(true)
    const refused = await running
    expect(refused).toMatchObject({ code: 'unavailable' })
    expect(refused?.message).toBe('The run was stopped. No note was written.')
    // The run is finished, so its id can be used again.
    expect(() => context.noteRuns.start('r1')).not.toThrow()
  })

  it('refuses a second run with an id that is running', async () => {
    const { context, sessions } = contextFor(['Index.md\n', 'Index.md\n'], ok(''))
    waitingSession(context, sessions)
    const first = failure(
      handleMessage('agent.run', { kind: 'note', what: 'note', prompt: 'x', run: 'r1' }, context),
    )
    await tick()
    const refused = await failure(
      handleMessage('agent.run', { kind: 'note', what: 'note', prompt: 'x', run: 'r1' }, context),
    )
    expect(refused).toMatchObject({ code: 'conflict' })
    await handleMessage('agent.stop', { run: 'r1' }, context)
    await first
  })

  it('answers agent.stop for an id that is not running with null', async () => {
    const { context } = contextFor([], ok(''))
    expect(await handleMessage('agent.stop', { run: 'nope' }, context)).toBeNull()
  })

  it('still works without an id: no signal, no line handler', async () => {
    const { context, sessions } = contextFor(['Index.md\n', 'Index.md\na.md\n'], ok('a.md\n'))
    await handleMessage('agent.run', { kind: 'note', what: 'note', prompt: 'x' }, context)
    expect(sessions[0]?.signal).toBeUndefined()
    expect(sessions[0]?.onLine).toBeUndefined()
  })
})

describe('the run of a note edit', () => {
  // A vault whose note changes when the session ends, and the sessions that ran.
  function editContext(change: boolean) {
    const { context, sessions } = contextFor([], ok(''))
    let text = '# a\n'
    const base = context.runCli
    context.runCli = (run) =>
      run.args[0] === 'vault-read'
        ? Promise.resolve({ code: 0, stdout: text, stderr: '' })
        : run.args[0] === 'vault-search' || run.args[0] === 'vault-list'
          ? Promise.resolve({ code: 0, stdout: '', stderr: '' })
          : base(run)
    return { context, sessions, change: () => (text = change ? '# b\n' : text) }
  }
  const edit = (context: Context, extra: object = {}) =>
    handleMessage('agent.run', { kind: 'note-edit', path: 'a.md', prompt: 'x', ...extra }, context)

  it('gives Claude a signal and a line handler that publishes to the run, and Codex only the signal', async () => {
    for (const harness of ['Claude', 'Codex'] as const) {
      const { context, sessions } = editContext(false)
      const lines: string[] = []
      context.noteRuns.subscribe('r2', undefined, (data) =>
        lines.push((data as { line: string }).line),
      )
      context.noteSession = (run) => {
        sessions.push(run)
        run.onLine?.('{"type":"system"}')
        return Promise.resolve({ code: 0, stdout: 'EDITED', stderr: '' })
      }
      await failure(edit(context, { harness, run: 'r2' }))
      expect(sessions[0]?.signal).toBeDefined()
      if (harness === 'Claude') {
        expect(sessions[0]?.onLine).toBeDefined()
        expect(lines).toEqual(['{"type":"system"}'])
      } else {
        expect(sessions[0]?.onLine).toBeUndefined()
        expect(lines).toEqual([])
      }
    }
  })

  it('answers that the run was stopped when it was stopped and the note did not change', async () => {
    const { context, sessions } = editContext(false)
    waitingSession(context, sessions)
    const running = failure(edit(context, { harness: 'Claude', run: 'r3' }))
    await tick()
    await handleMessage('agent.stop', { run: 'r3' }, context)
    const refused = await running
    expect(refused?.message).toBe('The run was stopped and the note was not changed.')
  })

  it('returns the edit when it was stopped after the note changed', async () => {
    const { context, sessions, change } = editContext(true)
    waitingSession(context, sessions, change)
    const running = edit(context, { harness: 'Claude', run: 'r4' })
    await tick()
    await handleMessage('agent.stop', { run: 'r4' }, context)
    expect(await running).toMatchObject({
      kind: 'note-edit',
      edit: { before: '# a\n', after: '# b\n' },
    })
  })
})
