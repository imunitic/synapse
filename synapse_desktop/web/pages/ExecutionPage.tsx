import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { listRecordedDefinitions } from '../domain/definitions.ts'
import { sessionsByVisit, type Activity, type RecordedSession } from '../domain/activity.ts'
import {
  DELETE_ONE_CONFIRM,
  keptReasonText,
  readExecution,
  removeExecutions,
  setRunName,
  waitingFor,
  type ExecutionRecord,
} from '../domain/executions.ts'
import { layoutGraph } from '../domain/graph.ts'
import type { LiveSession } from '../domain/live.ts'
import { progressOf, visitsOf, type StepProgress, type Visit } from '../domain/progress.ts'
import { describeRun } from '../domain/run-graph.ts'
import { problemsOf, type VisitOutputRead } from '../domain/visit-outputs.ts'
import { isLiveRun, type TerminalSession } from '../state/state.ts'
import { transport } from '../transport/index.ts'
import { ActivityBody, ActivityView } from '../components/ActivityView.tsx'
import { SourceCard } from './DefinitionPage.tsx'
import { GraphView } from '../components/GraphView.tsx'
import { JsonTree } from '../components/JsonTree.tsx'
import { measureGraphText } from '../components/measure-text.ts'
import { TerminalView } from '../components/TerminalView.tsx'
import { StatusBadge } from '../components/StatusBadge.tsx'
import { useLoad } from '../state/useLoad.ts'
import { useVisitOutputs } from '../state/useVisitOutputs.ts'
import { useWatch } from '../state/useWatch.ts'

// What no file shows, such as a run that died, is looked for now and then.
const REFRESH_MS = 10_000

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// The run's title: its name, or its id when it has none. A click turns it into a field that names
// the run on Enter; Escape or leaving the field keeps the name as it was.
function RunTitle({
  id,
  name,
  onRename,
}: {
  id: string
  name: string | null
  onRename: (name: string) => void
}) {
  const [draft, setDraft] = useState<string | null>(null)
  if (draft !== null) {
    return (
      <input
        className="page-title"
        aria-label="Name of this run"
        maxLength={120}
        autoFocus
        value={draft}
        onChange={(event) => setDraft(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter') {
            setDraft(null)
            onRename(draft)
          } else if (event.key === 'Escape') {
            setDraft(null)
          }
        }}
        onBlur={() => setDraft(null)}
      />
    )
  }
  return (
    <>
      {/* The heading is named by what it shows: without this its name would be its button's. */}
      <h1 className={name === null ? 'page-title mono' : 'page-title'} aria-label={name ?? id}>
        <button
          aria-label="Rename this run"
          title="Rename this run"
          onClick={() => setDraft(name ?? '')}
        >
          {name ?? id}
        </button>
      </h1>
      {name !== null && <p className="muted mono small">{id}</p>}
    </>
  )
}

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
  onShowChanges,
  onShowChange,
}: {
  visit: Visit
  status: ExecutionRecord['summary']['status']
  sessions: RecordedSession[]
  onShowChanges: () => void
  // A file the activity changed is shown in the sidebar, among the run's changes.
  onShowChange: (path: string) => void
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
        {sessions.length > 0 && (
          <button className="link" onClick={onShowChanges}>
            Changes
          </button>
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
            <ActivityView path={session.transcript} onShowChange={onShowChange} />
          </div>
        ))}
    </div>
  )
}

// What one visit reported: its summary, the problems it listed and its data. A visit that is going
// on, or that failed, has no outcome and nothing is read for it.
function OutcomeVisit({
  visit,
  status,
  output,
  open,
  onToggle,
}: {
  visit: Visit
  status: ExecutionRecord['summary']['status']
  output: VisitOutputRead | undefined
  open: boolean
  onToggle: () => void
}) {
  const finished = visit.outcome !== null
  const said = visitText(visit, status)
  const problems = output?.status === 'recorded' ? problemsOf(output.output.data) : []
  return (
    <div>
      <div className="trace-row mono">
        <span className="muted">{visit.n}</span>
        <span>{visit.step}</span>
        <span className="muted">{said === 'going on' ? 'running' : said}</span>
        {finished && (
          <button className="link" aria-expanded={open} onClick={onToggle}>
            {open ? 'Hide outcome' : 'Outcome'}
          </button>
        )}
      </div>
      {finished && open && (
        <div className="trace-session">
          {output === undefined ? (
            <p className="muted small">Loading…</p>
          ) : output.status === 'not-recorded' ? (
            <p className="muted small">not recorded</p>
          ) : (
            <>
              <p>{output.output.summary}</p>
              {problems.length > 0 && (
                <ul className="problems" aria-label="Problems">
                  {problems.map((problem, i) => (
                    <li key={i}>
                      {problem.file !== null && <span className="mono">{problem.file}</span>}
                      {problem.location !== null && (
                        <span className="mono muted"> {problem.location}</span>
                      )}
                      {problem.issue !== null && (
                        <span>
                          {problem.file !== null || problem.location !== null ? ': ' : ''}
                          {problem.issue}
                        </span>
                      )}
                    </li>
                  ))}
                </ul>
              )}
              <JsonTree value={output.output.data} />
            </>
          )}
        </div>
      )}
    </div>
  )
}

// What each visit of the run reported, in order. The newest finished visit is open; a row the
// person opened or closed stays so while the page is shown.
function Outcomes({
  id,
  visits,
  sessions,
  status,
}: {
  id: string
  visits: Visit[]
  sessions: RecordedSession[][]
  status: ExecutionRecord['summary']['status']
}) {
  const { outputs, read } = useVisitOutputs(id, visits, sessions)
  const [chosen, setChosen] = useState<ReadonlyMap<number, boolean>>(new Map())
  useEffect(() => setChosen(new Map()), [id])
  const newest = visits.findLast((v) => v.outcome !== null)?.n
  return (
    <section className="card" aria-label="Outcomes">
      <h2 className="card-title">Outcomes</h2>
      {visits.length === 0 && <p className="muted">No step has started.</p>}
      <div className="trace">
        {visits.map((visit) => {
          const open = chosen.get(visit.n) ?? visit.n === newest
          return (
            <OutcomeVisit
              key={visit.n}
              visit={visit}
              status={status}
              output={outputs.get(visit.n)}
              open={open}
              onToggle={() => {
                if (!open) read(visit)
                setChosen((before) => new Map(before).set(visit.n, !open))
              }}
            />
          )
        })}
      </div>
    </section>
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
  const graph = useMemo(
    () => (drawn === null ? null : layoutGraph(drawn.description, measureGraphText)),
    [drawn],
  )
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

// The step that is running now and what it has done so far, read from the transcript as it grows.
// It stays at the bottom while new actions come, unless the person has scrolled up.
function LiveCard({ live, activity }: { live: LiveSession; activity: Activity | null }) {
  const body = useRef<HTMLDivElement>(null)
  const atBottom = useRef(true)
  useEffect(() => {
    const element = body.current
    if (element !== null && atBottom.current) element.scrollTop = element.scrollHeight
  }, [activity])
  return (
    <section className="card" aria-label="Live step">
      <h2 className="card-title">
        Running: {live.step} <span className="muted small">attempt {live.attempt}</span>
      </h2>
      <div
        ref={body}
        className="live-card-body"
        onScroll={(event) => {
          const e = event.currentTarget
          atBottom.current = e.scrollHeight - e.scrollTop - e.clientHeight < 24
        }}
      >
        {activity === null || activity.actions.length === 0 ? (
          <p className="muted small">Nothing has been said yet.</p>
        ) : (
          <ActivityBody activity={activity} empty="Nothing has been said yet." />
        )}
      </div>
    </section>
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
export function ExecutionPage({
  id,
  terminals,
  waiting,
  live,
  activity,
  onStopTerminal,
  onTerminalEnded,
  onTerminalClaimed,
  onTerminalRun,
  onShowChanges,
  onExecutionsRemoved,
}: {
  id: string
  // The sessions of the terminals, one of which may be an interactive run of this execution.
  terminals: readonly TerminalSession[]
  // What the agent of each interactive run that waits for a person said, by execution.
  waiting: ReadonlyMap<string, string>
  // The running session of a run without a terminal and what it has done so far.
  live: LiveSession | null
  activity: Activity | null
  // A session is closed: it ends, and so does the run in it if it is going on.
  onStopTerminal: (session: string) => void
  onTerminalEnded: (session: string) => void
  onTerminalClaimed: (session: string) => void
  onTerminalRun: (session: string, executionId: string) => void
  // The Changes sidebar is opened on the run's changes, at a file when one is named.
  onShowChanges: (path?: string) => void
  // Runs whose records were deleted; their pages, this one among them, are closed.
  onExecutionsRemoved: (ids: string[]) => void
}) {
  const terminal = terminals.find((t) => t.kind === 'Pipeline' && t.executionId === id)
  const load = useCallback(() => readExecution(transport, id), [id])
  const { state, reload } = useLoad(load, REFRESH_MS)
  useWatch('work', reload)
  // What went wrong when the run was stopped, renamed or deleted.
  const [actionError, setActionError] = useState<string | null>(null)
  // Whether the person opened or closed the card of the terminal; until then it is open while the
  // run goes on.
  const [terminalOpen, setTerminalOpen] = useState<boolean | null>(null)

  async function stop() {
    try {
      await transport.stopRun(id)
      setActionError(null)
      reload()
    } catch (error) {
      setActionError(`Could not stop the run: ${String(error)}`)
    }
  }

  async function rename(name: string) {
    try {
      await setRunName(transport, id, name)
      setActionError(null)
      reload()
    } catch (error) {
      setActionError(`Could not rename the run: ${messageOf(error)}`)
    }
  }

  async function remove() {
    try {
      const result = await removeExecutions(transport, [id])
      if (result.removed.length > 0) {
        onExecutionsRemoved(result.removed)
        return
      }
      const kept = result.kept[0]
      setActionError(
        `Could not delete the run: ${kept === undefined ? 'kept' : keptReasonText(kept.reason)}`,
      )
    } catch (error) {
      setActionError(`Could not delete the run: ${messageOf(error)}`)
    }
  }

  if (state.status === 'loading') return <p className="muted">Loading…</p>
  if (state.status === 'failed') return <p role="alert">Could not read the run: {state.error}</p>

  const record = state.data
  const { summary, events } = record
  const visits = visitsOf(events)
  const sessions = sessionsByVisit(events)
  const terminalLive = terminal !== undefined && isLiveRun(terminal)
  // A run is read before its record is complete, so a live session also counts as going on.
  const open = terminalOpen ?? (terminalLive || summary.status === 'running')
  const waitingText = waitingFor(summary)
  return (
    <div className="page full">
      <div className="page-head">
        <div>
          <p className="eyebrow">Execution</p>
          <RunTitle id={summary.id} name={summary.name} onRename={(name) => void rename(name)} />
        </div>
        {terminal !== undefined && terminalLive && (
          <div className="head-actions">
            <button
              className="danger"
              onClick={() => {
                // Ending a run that is going on stops it, so it is asked.
                if (
                  window.confirm(`Stop the run of ${summary.pipeline ?? id}? Its agent is ended.`)
                ) {
                  onStopTerminal(terminal.id)
                }
              }}
            >
              Stop run
            </button>
          </div>
        )}
        {summary.status === 'running' && terminal === undefined && (
          <div className="head-actions">
            <button className="danger" onClick={() => void stop()}>
              Stop run
            </button>
            <span className="muted small">Only for runs started from this app.</span>
          </div>
        )}
        {summary.status !== 'running' && !terminalLive && (
          <div className="head-actions">
            <button
              className="danger"
              onClick={() => {
                if (window.confirm(DELETE_ONE_CONFIRM)) void remove()
              }}
            >
              Delete
            </button>
          </div>
        )}
      </div>
      {actionError !== null && (
        <p className="error" role="alert">
          {actionError}
        </p>
      )}
      {/* A run with its terminal open says it there, in the view of the terminal. */}
      {waitingText !== null && (terminal === undefined || !open) && (
        <p className="attention-banner" role="status">
          <strong>Waiting for you.</strong>
          {waitingText !== '' && <span> {waitingText}</span>}
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
      {live !== null && terminal === undefined && <LiveCard live={live} activity={activity} />}
      {terminal !== undefined && (
        <section className="card terminal-card" aria-label="Terminal">
          <div className="terminal-card-head">
            <h2 className="card-title">Terminal</h2>
            <button
              className="secondary"
              aria-expanded={open}
              onClick={() => setTerminalOpen(!open)}
            >
              {open ? 'Hide terminal' : 'Show terminal'}
            </button>
          </div>
          {/* Hidden, the view stays mounted, so that the session stays attached. */}
          <TerminalView
            session={terminal}
            visible={open}
            onClose={() => onStopTerminal(terminal.id)}
            onEnded={() => onTerminalEnded(terminal.id)}
            onClaimed={() => onTerminalClaimed(terminal.id)}
            onRun={(executionId) => onTerminalRun(terminal.id, executionId)}
            waitingFor={waiting.get(id) ?? null}
          />
        </section>
      )}
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
              onShowChanges={() => onShowChanges()}
              onShowChange={(path) => onShowChanges(path)}
            />
          ))}
        </div>
      </section>
      <Outcomes id={id} visits={visits} sessions={sessions} status={summary.status} />
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
