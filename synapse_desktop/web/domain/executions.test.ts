import { describe, expect, it } from 'vitest'
import { fakeTransport } from './fake-transport.ts'
import {
  listExecutions,
  parseEvents,
  parseExecution,
  readExecution,
  waitingFor,
} from './executions.ts'

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

const paths = { definitionDirs: [], skillsDir: null, recordsDir: '/w/pipelines' }

describe('parseExecution', () => {
  it('reads a completed record', () => {
    expect(parseExecution('exec-04b1adfc', COMPLETED)).toEqual({
      id: 'exec-04b1adfc',
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
    const none = { definitionDirs: [], skillsDir: null, recordsDir: null }
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
