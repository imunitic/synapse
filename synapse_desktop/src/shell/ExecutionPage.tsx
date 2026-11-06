import { useCallback } from 'react'
import { readExecution } from '../domain/executions.ts'
import { transport } from '../transport/index.ts'
import { StatusBadge } from './StatusBadge.tsx'
import { useLoad } from './useLoad.ts'

const REFRESH_MS = 2000

function formatTime(iso: string | null): string {
  if (iso === null) return '—'
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleString()
}

// One run: its summary and the events of its record.
export function ExecutionPage({ id }: { id: string }) {
  const load = useCallback(() => readExecution(transport, id), [id])
  const { state } = useLoad(load, REFRESH_MS)

  if (state.status === 'loading') return <p className="muted">Loading…</p>
  if (state.status === 'failed') return <p role="alert">Could not read the run: {state.error}</p>

  const { summary, events } = state.data
  return (
    <div className="page wide">
      <p className="eyebrow">Execution</p>
      <h1 className="page-title mono">{summary.id}</h1>
      <div className="row">
        <StatusBadge status={summary.status} />
        <span>{summary.pipeline ?? 'unknown pipeline'}</span>
      </div>
      {summary.failure !== null && (
        <div className="alert" role="alert">
          {summary.failure}
        </div>
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
