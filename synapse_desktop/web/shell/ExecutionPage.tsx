import { useCallback, useMemo, useState } from 'react'
import { listRecordedDefinitions } from '../domain/definitions.ts'
import { sessionsByVisit, type RecordedSession } from '../domain/activity.ts'
import { readExecution, type ExecutionRecord } from '../domain/executions.ts'
import { layoutGraph } from '../domain/graph.ts'
import { progressOf, visitsOf, type StepProgress, type Visit } from '../domain/progress.ts'
import { describeRun } from '../domain/run-graph.ts'
import { transport } from '../transport/index.ts'
import { ActivityView } from './ActivityView.tsx'
import { SourceCard } from './DefinitionPage.tsx'
import { GraphView } from './GraphView.tsx'
import { StatusBadge } from './StatusBadge.tsx'
import { useLoad } from './useLoad.ts'

const REFRESH_MS = 2000

function formatTime(iso: string | null): string {
  if (iso === null) return '—'
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleString()
}

// What a step's box says about the run, in words.
function subtitle(step: StepProgress): string {
  const visits = step.visits > 1 ? ` ×${step.visits}` : ''
  switch (step.state) {
    case 'current':
      return `running${visits}`
    case 'interrupted':
      return `interrupted${visits}`
    case 'failed':
      return `failed${visits}`
    case 'done':
      return `${step.outcome ?? 'done'}${visits}`
    case 'idle':
      return 'not reached'
  }
}

// How a step visit ended, in words. A visit with no outcome is going on only
// while the run is; a run that failed or died ended it.
function visitText(visit: Visit, status: ExecutionRecord['summary']['status']): string {
  if (visit.outcome !== null) return `${visit.outcome} → ${visit.next ?? 'the run completes'}`
  if (status === 'failed') return 'failed'
  if (status === 'interrupted') return 'interrupted'
  return 'going on'
}

// A visit to a step, with what the agent did in it once its session has ended.
function TraceVisit({
  visit,
  status,
  sessions,
}: {
  visit: Visit
  status: ExecutionRecord['summary']['status']
  sessions: RecordedSession[]
}) {
  const [open, setOpen] = useState(false)
  const written = sessions.filter(
    (s): s is RecordedSession & { transcript: string } => s.transcript !== null,
  )
  return (
    <div>
      <div className="trace-row">
        <span className="muted">{visit.n}</span>
        <span>{visit.step}</span>
        <span className="muted">{visitText(visit, status)}</span>
        {written.length > 0 ? (
          <button className="link" aria-expanded={open} onClick={() => setOpen(!open)}>
            {open ? 'Hide activity' : 'Activity'}
          </button>
        ) : (
          sessions.length > 0 && <span className="muted small">no transcript</span>
        )}
      </div>
      {open &&
        written.map((session) => (
          <div key={session.transcript} className="trace-session">
            {written.length > 1 && (
              <p className="muted small">
                Try {session.attempt}: {session.succeeded ? 'ended well' : 'failed'}
              </p>
            )}
            <ActivityView path={session.transcript} />
          </div>
        ))}
    </div>
  )
}

// The run on its pipeline: where it has been, which edges it took, where it is.
function RunGraph({ id, record }: { id: string; record: ExecutionRecord }) {
  const pipeline = record.summary.pipeline
  // Loaded once: a run that is going gives its pipeline exactly, and the
  // answer does not change while it runs.
  const going = record.summary.status === 'running'
  const load = useCallback(
    () => (pipeline === null ? Promise.resolve(null) : describeRun(transport, id, pipeline, going)),
    [id, pipeline, going],
  )
  const { state } = useLoad(load)
  const drawn = state.status === 'ready' && state.data?.ok ? state.data : null
  const graph = useMemo(() => (drawn === null ? null : layoutGraph(drawn.description)), [drawn])
  const progress = useMemo(
    () => (drawn === null ? null : progressOf(drawn.description, record.events, record.summary)),
    [drawn, record],
  )

  if (state.status === 'loading') return <p className="muted">Loading the graph…</p>
  if (state.status === 'failed') return <p role="alert">Could not draw the run: {state.error}</p>
  if (state.data === null) return null
  if (!state.data.ok) {
    return (
      <p className="muted">
        The graph is not drawn: {pipeline} cannot be described now (
        {state.data.problems[0]?.message}
        ).
      </p>
    )
  }
  if (drawn === null || graph === null || progress === null) return null

  const states = Object.fromEntries(Object.entries(progress.steps).map(([k, v]) => [k, v.state]))
  const subtitles = Object.fromEntries(
    Object.entries(progress.steps).map(([k, v]) => [k, subtitle(v)]),
  )
  if (graph.nodes.some((n) => n.isEnd)) {
    states['End'] = progress.endReached ? 'done' : 'idle'
  }

  return (
    <>
      {!drawn.exact && (
        <p className="muted small">
          Drawn on the pipeline as it is now: the record of a run that is over does not keep the
          definition it ran.
        </p>
      )}
      {progress.unknownSteps.length > 0 && (
        <p className="warn-line" role="status">
          The pipeline has changed since this run: {progress.unknownSteps.join(', ')} are no longer
          in it.
        </p>
      )}
      <section className="card graph-card" aria-label="Run graph">
        <GraphView
          graph={graph}
          subtitles={subtitles}
          states={states}
          arcCounts={progress.arcCounts}
          flowCounts={progress.flowCounts}
        />
      </section>
    </>
  )
}

// The definition files the run's record keeps, as they were when it began. A
// record made before it kept them has none, and shows nothing here.
function RecordedFiles({ id }: { id: string }) {
  const load = useCallback(() => listRecordedDefinitions(transport, id), [id])
  const { state } = useLoad(load)
  const [open, setOpen] = useState<string | null>(null)
  if (state.status !== 'ready') return null
  const { definitions, skills } = state.data
  if (definitions.length === 0 && skills.length === 0) return null
  const files = [
    ...definitions.map((d) => ({ label: `${d.kind} ${d.name}`, path: d.path })),
    ...skills.map((s) => ({ label: `skill ${s.name}`, path: s.path })),
  ]
  return (
    <section className="card" aria-label="Definitions it ran">
      <h2 className="card-title">Definitions it ran</h2>
      <p className="muted small">The files as they were when the run began.</p>
      <div className="chips">
        {files.map((file) => (
          <button
            key={file.path}
            className="chip mono"
            aria-pressed={open === file.path}
            onClick={() => setOpen(open === file.path ? null : file.path)}
          >
            {file.label}
          </button>
        ))}
      </div>
      {open !== null && <SourceCard path={open} />}
    </section>
  )
}

// One run: where it is on its pipeline, its summary, the steps it went through
// and the events of its record.
export function ExecutionPage({ id }: { id: string }) {
  const load = useCallback(() => readExecution(transport, id), [id])
  const { state, reload } = useLoad(load, REFRESH_MS)
  const [stopError, setStopError] = useState<string | null>(null)

  async function stop() {
    try {
      await transport.stopRun(id)
      setStopError(null)
      reload()
    } catch (error) {
      setStopError(String(error))
    }
  }

  if (state.status === 'loading') return <p className="muted">Loading…</p>
  if (state.status === 'failed') return <p role="alert">Could not read the run: {state.error}</p>

  const record = state.data
  const { summary, events } = record
  const visits = visitsOf(events)
  const sessions = sessionsByVisit(events)
  return (
    <div className="page full">
      <div className="page-head">
        <div>
          <p className="eyebrow">Execution</p>
          <h1 className="page-title mono">{summary.id}</h1>
        </div>
        {summary.status === 'running' && (
          <div className="head-actions">
            <button className="danger" onClick={() => void stop()}>
              Stop run
            </button>
            <span className="muted small">Only for runs started from this app.</span>
          </div>
        )}
      </div>
      {stopError !== null && (
        <p className="error" role="alert">
          Could not stop the run: {stopError}
        </p>
      )}
      <div className="row">
        <StatusBadge status={summary.status} />
        <span>{summary.pipeline ?? 'unknown pipeline'}</span>
      </div>
      {summary.failure !== null && (
        <div className="alert" role="alert">
          {summary.failure}
        </div>
      )}
      <RunGraph id={id} record={record} />
      <section className="card" aria-label="Summary">
        <h2 className="card-title">Summary</h2>
        <dl className="facts">
          <dt>Started</dt>
          <dd>{formatTime(summary.started)}</dd>
          <dt>Ended</dt>
          <dd>{formatTime(summary.ended)}</dd>
          <dt>Current step</dt>
          <dd className="mono">{summary.currentStep ?? '—'}</dd>
          <dt>Steps run</dt>
          <dd>{summary.stepsRun ?? '—'}</dd>
        </dl>
      </section>
      <RecordedFiles id={id} />
      <section className="card" aria-label="Trace">
        <h2 className="card-title">Trace</h2>
        {visits.length === 0 && <p className="muted">No step has started.</p>}
        <div className="trace mono">
          {visits.map((visit) => (
            <TraceVisit
              key={visit.n}
              visit={visit}
              status={summary.status}
              sessions={sessions[visit.n - 1] ?? []}
            />
          ))}
        </div>
      </section>
      <section className="card" aria-label="Events">
        <h2 className="card-title">Events</h2>
        {events.length === 0 && <p className="muted">No events recorded.</p>}
        <div className="events mono">
          {events.map((event) => (
            <div key={event.sequence} className="event">
              <span className="muted">{event.sequence}</span>
              <span>{event.kind}</span>
              <span className="muted">{event.step ?? ''}</span>
              <span className="muted">
                {event.detail === null || event.detail === undefined
                  ? ''
                  : JSON.stringify(event.detail)}
              </span>
            </div>
          ))}
        </div>
      </section>
    </div>
  )
}
