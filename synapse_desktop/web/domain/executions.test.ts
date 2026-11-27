import { describe, expect, it } from 'vitest'
import { fakeTransport } from './fake-transport.ts'
import type { CliBinary, CliResult } from '../../shared/transport.ts'
import {
  type ExecutionSummary,
  keptReasonText,
  listExecutions,
  parseEvents,
  parseExecution,
  planCleanup,
  readExecution,
  readSummary,
  removeExecutions,
  runLabel,
  runRow,
  setRunName,
  waitingFor,
} from './executions.ts'
import { formatStartTime } from './format.ts'

// Records written by a real run (the scripted runner).
const COMPLETED =
  '{"format":"synapse-pipeline-execution/v1","id":"exec-04b1adfc","pipeline":"Develop_Feature","started":"2026-11-06T23:42:44+01:00","ended":"2026-11-06T23:42:44+01:00","status":"completed","current_step":null,"state":{"format":"synapse-pipeline-state/v1","pipeline":"Develop_Feature","status":"completed","current_step":"","initial_input":{"task":"add a --verbose flag"},"previous_output":{"outcome":"Approved","summary":"looks good","data":{}},"fired":[1],"steps_run":6,"failure":null}}'
const FAILED =
  '{"format":"synapse-pipeline-execution/v1","id":"exec-07baedc0","pipeline":"Develop_Feature","started":"2026-11-06T23:50:00+01:00","ended":"2026-11-06T23:50:01+01:00","status":"failed","current_step":null,"state":{"format":"synapse-pipeline-state/v1","pipeline":"Develop_Feature","status":"failed","current_step":"Test","initial_input":{"task":"speed up the startup"},"previous_output":{"outcome":"Done","summary":"built it","data":{}},"fired":[0],"steps_run":1,"failure":{"kind":"execution_error","step":"Test","message":"the session ran past its limit","reset":null}}}'

function running(id: string, started: string): string {
  return JSON.stringify({
    format: 'synapse-pipeline-execution/v1',
    id,
    pipeline: 'P',
    started,
    ended: null,
    status: 'running',
    current_step: 'Review',
    state: { steps_run: 2, failure: null },
  })
}

const paths = { definitionDirs: [], recordsDir: '/w/pipelines' }

describe('parseExecution', () => {
  it('reads a completed record', () => {
    expect(parseExecution('exec-04b1adfc', COMPLETED)).toEqual({
      id: 'exec-04b1adfc',
      name: null,
      pipeline: 'Develop_Feature',
      status: 'completed',
      started: '2026-11-06T23:42:44+01:00',
      ended: '2026-11-06T23:42:44+01:00',
      currentStep: null,
      stepsRun: 6,
      failure: null,
      failureStep: null,
      fired: [1],
      attention: null,
      interactive: null,
    })
  })

  it('reads whether a run is interactive, and null when the record does not say', () => {
    const record = JSON.parse(COMPLETED)
    const read = (extra: object) =>
      parseExecution('exec-04b1adfc', JSON.stringify({ ...record, ...extra }))
    expect(read({ interactive: true })?.interactive).toBe(true)
    expect(read({ interactive: false })?.interactive).toBe(false)
    expect(read({})?.interactive).toBeNull()
  })

  it('reads whether an interactive run is waiting for a person, and what its agent said', () => {
    const text = JSON.stringify({
      ...JSON.parse(running('exec-a', '2026-11-15T10:00:00+01:00')),
      attention: { state: 'waiting', reason: 'Which color?', since: '2026-11-15T10:00:05+01:00' },
    })
    const summary = parseExecution('exec-a', text)
    expect(summary?.attention).toEqual({
      state: 'waiting',
      reason: 'Which color?',
      since: '2026-11-15T10:00:05+01:00',
    })
    expect(summary === null ? null : waitingFor(summary)).toBe('Which color?')
    // A run that is working waits for nobody, and neither does one that is not interactive.
    const working = parseExecution(
      'exec-a',
      JSON.stringify({
        ...JSON.parse(text),
        attention: { state: 'running', reason: null, since: '2026-11-15T10:00:05+01:00' },
      }),
    )
    expect(working?.attention?.state).toBe('running')
    expect(working === null ? 'x' : waitingFor(working)).toBeNull()
    const plain = parseExecution('exec-04b1adfc', COMPLETED)
    expect(plain === null ? 'x' : waitingFor(plain)).toBeNull()
  })

  it('does not say a run waits that has ended or died', () => {
    const waiting = {
      ...JSON.parse(running('exec-a', '2026-11-15T10:00:00+01:00')),
      attention: { state: 'waiting', reason: 'Which?', since: 't' },
    }
    const summary = parseExecution('exec-a', JSON.stringify(waiting))
    expect(summary).not.toBeNull()
    if (summary === null) return
    expect(waitingFor({ ...summary, status: 'interrupted' })).toBeNull()
    expect(waitingFor({ ...summary, status: 'completed' })).toBeNull()
  })

  it('reads the failure of a failed record', () => {
    expect(parseExecution('exec-07baedc0', FAILED)).toMatchObject({
      status: 'failed',
      failure: 'the session ran past its limit',
      failureStep: 'Test',
      fired: [0],
    })
  })

  it('refuses text that is not a record, another format, or another run', () => {
    expect(parseExecution('exec-04b1adfc', '{"half"')).toBeNull()
    expect(parseExecution('exec-04b1adfc', COMPLETED.replace('/v1', '/v2'))).toBeNull()
    expect(parseExecution('exec-other', COMPLETED)).toBeNull()
  })
})

describe('parseEvents', () => {
  const one = '{"sequence":1,"kind":"run.started","step":"Develop","detail":{"pipeline":"P"}}'
  const two = '{"sequence":2,"kind":"step.started","step":"Develop","detail":null}'

  it('reads one event a line', () => {
    expect(parseEvents(`${one}\n${two}\n`).map((e) => e.sequence)).toEqual([1, 2])
  })

  it('leaves out a last line that has no line feed, which may be half written', () => {
    expect(parseEvents(`${one}\n${two}`).map((e) => e.sequence)).toEqual([1])
  })

  it('leaves out blank lines and lines that are not events', () => {
    expect(parseEvents(`${one}\n\nnot json\n{"kind":"x"}\n${two}\n`)).toHaveLength(2)
  })
})

describe('listExecutions', () => {
  it('is empty without a work directory or records directory', async () => {
    const none = { definitionDirs: [], recordsDir: null }
    expect(await listExecutions(fakeTransport({ paths: none, files: {} }))).toEqual([])
  })

  it('lists newest first, with the status each record and its socket give', async () => {
    const transport = fakeTransport({
      paths,
      listening: ['exec-live'],
      files: {
        '/w/pipelines/exec-04b1adfc/execution.json': COMPLETED,
        '/w/pipelines/exec-07baedc0/execution.json': FAILED,
        '/w/pipelines/exec-live/execution.json': running('exec-live', '2026-11-07T08:00:00+01:00'),
        '/w/pipelines/exec-dead/execution.json': running('exec-dead', '2026-11-05T08:00:00+01:00'),
        '/w/pipelines/exec-torn/execution.json': '{"half"',
      },
    })
    const list = await listExecutions(transport)
    expect(list.map((e) => [e.id, e.status])).toEqual([
      ['exec-live', 'running'],
      ['exec-07baedc0', 'failed'],
      ['exec-04b1adfc', 'completed'],
      ['exec-dead', 'interrupted'],
      ['exec-torn', 'incomplete'],
    ])
  })

  it('shows an interactive run that answers on its socket as running, and one that does not as interrupted', async () => {
    const interactive = (id: string) =>
      JSON.stringify({
        ...JSON.parse(running(id, '2026-11-07T08:00:00+01:00')),
        attention: { state: 'running', reason: null, since: '2026-11-07T08:00:00+01:00' },
      })
    const transport = fakeTransport({
      paths,
      listening: ['exec-asking'],
      files: {
        '/w/pipelines/exec-asking/execution.json': interactive('exec-asking'),
        '/w/pipelines/exec-gone/execution.json': interactive('exec-gone'),
      },
    })
    const list = await listExecutions(transport)
    expect(list.map((e) => [e.id, e.status, e.attention?.state])).toEqual([
      ['exec-asking', 'running', 'running'],
      ['exec-gone', 'interrupted', 'running'],
    ])
  })

  it('treats a record directory with no summary as incomplete', async () => {
    const transport = fakeTransport({
      paths,
      files: { '/w/pipelines/exec-new/events.jsonl': '' },
    })
    expect((await listExecutions(transport))[0]).toMatchObject({
      id: 'exec-new',
      status: 'incomplete',
    })
  })
})

describe('readExecution', () => {
  it('returns the summary and the events of one record', async () => {
    const transport = fakeTransport({
      paths,
      files: {
        '/w/pipelines/exec-04b1adfc/execution.json': COMPLETED,
        '/w/pipelines/exec-04b1adfc/events.jsonl':
          '{"sequence":1,"kind":"run.started","step":"Develop","detail":null}\n',
      },
    })
    const record = await readExecution(transport, 'exec-04b1adfc')
    expect(record.summary.status).toBe('completed')
    expect(record.events).toHaveLength(1)
  })

  it('returns no events when the file is missing', async () => {
    const transport = fakeTransport({
      paths,
      files: { '/w/pipelines/exec-04b1adfc/execution.json': COMPLETED },
    })
    expect((await readExecution(transport, 'exec-04b1adfc')).events).toEqual([])
  })
})

describe('run names', () => {
  it('reads the name from the record and trims it', async () => {
    const transport = fakeTransport({
      paths,
      files: {
        '/w/pipelines/exec-04b1adfc/execution.json': COMPLETED,
        '/w/pipelines/exec-04b1adfc/name': '  Fix login \n',
      },
    })
    expect((await readSummary(transport, 'exec-04b1adfc')).name).toBe('Fix login')
  })

  it('gives no name when the name file is missing or empty', async () => {
    const transport = fakeTransport({
      paths,
      files: {
        '/w/pipelines/exec-04b1adfc/execution.json': COMPLETED,
        '/w/pipelines/exec-07baedc0/execution.json': FAILED,
        '/w/pipelines/exec-07baedc0/name': '   ',
      },
    })
    expect((await readSummary(transport, 'exec-04b1adfc')).name).toBeNull()
    expect((await readSummary(transport, 'exec-07baedc0')).name).toBeNull()
  })

  it('labels a named run with its name, and the pipeline and start under it', () => {
    const run = parseExecution('exec-04b1adfc', COMPLETED) as ExecutionSummary
    const start = formatStartTime('2026-11-06T23:42:44+01:00')
    expect(runLabel({ ...run, name: 'Fix login' })).toEqual({
      title: 'Fix login',
      note: `Develop_Feature · ${start}`,
    })
  })

  it('labels an unnamed run with the pipeline and start, and no note', () => {
    const run = parseExecution('exec-04b1adfc', COMPLETED) as ExecutionSummary
    const start = formatStartTime('2026-11-06T23:42:44+01:00')
    expect(runLabel(run)).toEqual({ title: `Develop_Feature · ${start}`, note: null })
    expect(runLabel({ ...run, pipeline: null }).title).toBe(`unknown pipeline · ${start}`)
  })
})

// A transport whose CLI records each call and answers with `answer`.
function cliTransport(answer: (args: readonly string[]) => CliResult) {
  const calls: (readonly string[])[] = []
  const transport = fakeTransport({
    paths,
    files: {},
    cli: (_binary: CliBinary, args) => {
      calls.push(args)
      return answer(args)
    },
  })
  return { transport, calls }
}

function cleanupAnswer(removed: string[], kept: { id: string; reason: string }[] = []): CliResult {
  const document = { format: 'synapse-pipeline-cleanup/v1', dry_run: false, removed, kept }
  return { code: kept.length > 0 ? 1 : 0, stdout: JSON.stringify(document), stderr: '' }
}

describe('setRunName', () => {
  it('names a run', async () => {
    const { transport, calls } = cliTransport(() => ({ code: 0, stdout: '', stderr: '' }))
    await setRunName(transport, 'exec-a', '  Second try ')
    expect(calls).toEqual([['name', 'exec-a', 'Second try']])
  })

  it('clears the name when the name is empty', async () => {
    const { transport, calls } = cliTransport(() => ({ code: 0, stdout: '', stderr: '' }))
    await setRunName(transport, 'exec-a', '   ')
    expect(calls).toEqual([['name', 'exec-a']])
  })

  it('throws with what the engine said when it refuses', async () => {
    const { transport } = cliTransport(() => ({
      code: 1,
      stdout: '',
      stderr: 'error: no execution exec-a\n',
    }))
    await expect(setRunName(transport, 'exec-a', 'x')).rejects.toThrow('error: no execution exec-a')
  })
})

describe('removeExecutions', () => {
  it('sends 65 ids in three batches and merges what they answer', async () => {
    const ids = Array.from({ length: 65 }, (_, i) => `exec-${i}`)
    const { transport, calls } = cliTransport((args) => {
      const batch = args.slice(3)
      return batch.includes('exec-64')
        ? cleanupAnswer(
            batch.filter((id) => id !== 'exec-64'),
            [{ id: 'exec-64', reason: 'running' }],
          )
        : cleanupAnswer([...batch])
    })
    const result = await removeExecutions(transport, ids)
    expect(calls.map((c) => c.length - 3)).toEqual([30, 30, 5])
    expect(calls.every((c) => c.slice(0, 3).join(' ') === 'cleanup --format json')).toBe(true)
    expect(result.removed).toEqual(ids.slice(0, 64))
    expect(result.kept).toEqual([{ id: 'exec-64', reason: 'running' }])
  })

  it('throws with the stderr text when the answer is not JSON', async () => {
    const { transport } = cliTransport(() => ({
      code: 2,
      stdout: 'usage: ...',
      stderr: 'error: unknown option',
    }))
    await expect(removeExecutions(transport, ['exec-a'])).rejects.toThrow('error: unknown option')
  })
})

describe('keptReasonText', () => {
  it('says each reason the engine gives in words', () => {
    expect(keptReasonText('running')).toBe('running')
    expect(keptReasonText('not_found')).toBe('not found')
    expect(keptReasonText('cannot_remove')).toBe('cannot be removed')
  })

  it('shows a reason it does not know as the engine wrote it', () => {
    expect(keptReasonText('too_recent')).toBe('too_recent')
  })
})

describe('planCleanup', () => {
  it('asks for a dry run of the age cleanup, and of the cleanup of every finished run', async () => {
    const { transport, calls } = cliTransport(() => cleanupAnswer(['exec-old']))
    expect(await planCleanup(transport, { kind: 'olderThan', days: 7 })).toEqual({
      removed: ['exec-old'],
      kept: [],
    })
    await planCleanup(transport, { kind: 'all' })
    expect(calls).toEqual([
      ['cleanup', '--older-than', '7d', '--dry-run', '--format', 'json'],
      ['cleanup', '--all', '--dry-run', '--format', 'json'],
    ])
  })
})

describe('the row of a run in the sidebar', () => {
  const start = formatStartTime('2026-11-06T23:42:44+01:00')
  const run: ExecutionSummary = {
    ...(parseExecution('exec-04b1adfc', COMPLETED) as ExecutionSummary),
    interactive: true,
    currentStep: 'Review',
  }

  it('is the pipeline, with the start time, the kind of run and the step under it', () => {
    expect(runRow({ ...run, name: null })).toEqual({
      title: 'Develop_Feature',
      details: [start, 'interactive', 'Review'],
    })
  })

  it('is the name of a named run, with the pipeline first under it', () => {
    expect(runRow({ ...run, name: 'Fix login', interactive: false, currentStep: null })).toEqual({
      title: 'Fix login',
      details: ['Develop_Feature', start, 'autonomous'],
    })
  })

  it('leaves out what is not known', () => {
    expect(
      runRow({
        ...run,
        name: null,
        pipeline: null,
        started: null,
        interactive: null,
        currentStep: null,
      }),
    ).toEqual({ title: 'unknown pipeline', details: [] })
  })
})
