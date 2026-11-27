import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { HostError } from '../shared/dispatch.ts'
import type { CliResult } from '../shared/transport.ts'
import { handleMessage, type Context } from './calls.ts'
import type { CliRun } from './cli.ts'
import type { NoteSessionRun } from './note-agent.ts'
import { createNoteRuns } from './note-runs.ts'
import { jsonAnswer, runInputPrompt } from './run-input.ts'

const declaration = {
  fields: [{ name: 'task_id', type: 'string', required: true, description: 'The task' }],
  single_text_field: 'task_id',
}

describe('the prompt for the input of a run', () => {
  it('the prompt holds the declaration, the description and the closing instruction', () => {
    const text = runInputPrompt(
      'Implement',
      declaration,
      '  the note about cloning  ',
      undefined,
      'Claude',
    )
    expect(text.startsWith('Fill in the input of the pipeline Implement')).toBe(true)
    expect(text).toContain(JSON.stringify(declaration, null, 2))
    expect(text).toContain('Description:\nthe note about cloning')
    expect(text).toContain('`synapse vault-search-text <words>`')
    expect(text).toContain('`synapse vault-read <path>`. Write nothing.')
    expect(
      text.endsWith(
        'Answer with one JSON object that satisfies the declaration, and nothing else: no prose, no code fence.',
      ),
    ).toBe(true)
  })

  it('the current JSON is given only when it says something', () => {
    const keep = 'add to this; keep what the description does not change'
    const said = '{\n  "task_id": "synapse-1"\n}'
    expect(runInputPrompt('P', declaration, 'd', said, 'Claude')).toContain(`${keep}.\n${said}`)
    for (const empty of [
      undefined,
      '{}',
      '{\n  "task_id": ""\n}',
      '{"n": 0, "l": [], "b": false}',
    ]) {
      expect(runInputPrompt('P', declaration, 'd', empty, 'Claude')).not.toContain(keep)
    }
  })

  it('Codex gets no command rules', () => {
    const rule = 'Run one command in each Bash call'
    expect(runInputPrompt('P', declaration, 'd', undefined, 'Claude')).toContain(rule)
    expect(runInputPrompt('P', declaration, 'd', undefined, 'Opencode')).toContain(rule)
    expect(runInputPrompt('P', declaration, 'd', undefined, 'Codex')).not.toContain(rule)
  })
})

describe('the JSON in an answer', () => {
  it('is a plain object, pretty-printed', () => {
    expect(jsonAnswer(' {"a":1,"b":[2]} ')).toBe('{\n  "a": 1,\n  "b": [\n    2\n  ]\n}')
  })

  it('is the object inside a code fence', () => {
    expect(jsonAnswer('```json\n{"a": 1}\n```')).toBe('{\n  "a": 1\n}')
  })

  it('is the object after prose', () => {
    expect(jsonAnswer('Here is the input:\n{"a": "x"}')).toBe('{\n  "a": "x"\n}')
  })

  it('is nothing for an array', () => {
    expect(jsonAnswer('[{"a": 1}]')).toBeNull()
  })

  it('is nothing for prose', () => {
    expect(jsonAnswer('I could not find that note.')).toBeNull()
  })

  it('is nothing for broken JSON', () => {
    expect(jsonAnswer('{"a": 1,}')).toBeNull()
  })
})

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-run-input-'))
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

const ok = (stdout: string): CliResult => ({ code: 0, stdout, stderr: '' })

// A pipeline that declares `input`, whose check answers `checks` in turn, and sessions that
// answer `answers` in turn.
function contextFor(input: unknown, answers: CliResult[], checks: CliResult[] = [ok('')]) {
  const sessions: NoteSessionRun[] = []
  const ran: CliRun[] = []
  const context: Context = {
    environment: { env: { XDG_CONFIG_HOME: dir, MARK: 'x' }, home: dir },
    configFile: join(dir, 'config.json'),
    runCli: (run) => {
      ran.push(run)
      if (run.args[0] === 'show') return Promise.resolve(ok(JSON.stringify({ name: 'P', input })))
      if (run.args[0] === 'check') return Promise.resolve(checks.shift() ?? ok(''))
      return Promise.reject(new Error(`not used: ${run.args.join(' ')}`))
    },
    runs: { start: () => Promise.reject(new Error('not used')), stop: () => undefined },
    agent: () => Promise.reject(new Error('not used')),
    noteRuns: createNoteRuns(),
    noteSession: (run) => {
      sessions.push(run)
      return Promise.resolve(answers.shift() ?? ok(''))
    },
  }
  return { context, sessions, ran }
}

const fill = (context: Context, extra: object = {}) =>
  handleMessage(
    'agent.run',
    { kind: 'run-input', pipeline: 'P', prompt: 'the note about cloning', ...extra },
    context,
  )

const failure = async (action: Promise<unknown>) =>
  action.then(
    () => null,
    (error: unknown) => error as HostError,
  )

describe('filling in the input of a run', () => {
  it('a pipeline without Input is refused and starts no session', async () => {
    const { context, sessions } = contextFor(null, [ok('{}')])
    const refused = await failure(fill(context))
    expect(refused?.code).toBe('conflict')
    expect(refused?.message).toBe('P declares no input')
    expect(sessions).toEqual([])
  })

  it('a valid answer is returned pretty-printed after one session', async () => {
    const { context, sessions, ran } = contextFor(declaration, [
      ok('```json\n{"task_id":"synapse-1"}\n```'),
    ])
    const answer = await fill(context)
    expect(answer).toEqual({ kind: 'run-input', text: '{\n  "task_id": "synapse-1"\n}' })
    expect(sessions).toHaveLength(1)
    const check = ran.find((run) => run.args[0] === 'check')
    expect(check?.args).toEqual(['check', 'P', '--input', '-'])
    expect(check?.stdin).toBe('{\n  "task_id": "synapse-1"\n}')
  })

  it('an answer with problems gets one more session with the problems in its prompt', async () => {
    const { context, sessions } = contextFor(
      declaration,
      [ok('{"task_id": 1}'), ok('{"task_id": "synapse-1"}'), ok('{"never": true}')],
      [
        { code: 2, stdout: '', stderr: 'error: task_id is a string\nnot an error line\n' },
        { code: 2, stdout: '', stderr: 'error: again\n' },
      ],
    )
    const answer = await fill(context)
    expect(answer).toEqual({ kind: 'run-input', text: '{\n  "task_id": "synapse-1"\n}' })
    expect(sessions).toHaveLength(2)
    const second = sessions[1]?.prompt ?? ''
    expect(second).toContain(
      'These problems were found in your answer:\nerror: task_id is a string',
    )
    expect(second).not.toContain('not an error line')
    expect(second).toContain('The input holds this JSON now')
    expect(second).toContain('"task_id": 1')
  })

  it('an answer that is not JSON is refused with what the agent said', async () => {
    const { context } = contextFor(declaration, [ok('I could not find that note.\n')])
    const refused = await failure(fill(context))
    expect(refused?.code).toBe('unavailable')
    expect(refused?.message).toBe('The agent did not answer with JSON: I could not find that note.')
  })

  it('the session is a read session with no writable folders', async () => {
    const { context, sessions } = contextFor(declaration, [ok('{"task_id": "x"}')])
    await fill(context, { current: '{"task_id": "old"}' })
    expect(sessions[0]?.access).toBe('read')
    expect(sessions[0]?.writable).toEqual([])
    expect(sessions[0]?.env.MARK).toBe('x')
    expect(sessions[0]?.prompt).toContain('"task_id": "old"')
  })

  it('a stopped run says it was stopped', async () => {
    const { context } = contextFor(declaration, [])
    context.noteSession = (run) =>
      new Promise((resolve) => {
        run.signal?.addEventListener('abort', () => {
          resolve({ code: 143, stdout: '', stderr: '' })
        })
      })
    const running = failure(fill(context, { run: 'r1' }))
    await new Promise((resolve) => setTimeout(resolve, 10))
    await handleMessage('agent.stop', { run: 'r1' }, context)
    const refused = await running
    expect(refused?.message).toBe('The run was stopped.')
    expect(() => context.noteRuns.start('r1')).not.toThrow()
  })

  it('the default harness and model are used when none is given', async () => {
    const { context, sessions } = contextFor(declaration, [ok('{}'), ok('{}')])
    await handleMessage(
      'config.set',
      { patch: { defaultHarness: 'Codex', defaultModels: { Codex: 'gpt-x' } } },
      context,
    )
    await fill(context)
    await fill(context, { harness: 'Claude', model: 'opus' })
    expect(sessions.map((s) => [s.harness, s.model])).toEqual([
      ['Codex', 'gpt-x'],
      ['Claude', 'opus'],
    ])
    expect(sessions[0]?.prompt).not.toContain('Run one command in each Bash call')
  })
})
