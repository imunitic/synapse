import type { Dispatch } from 'react'
import { listExecutions, waitingFor } from '../domain/executions.ts'
import { transport } from '../transport/index.ts'
import { RefreshIcon } from '../components/icons.tsx'
import type { Action, ShellState } from '../state/state.ts'
import { StatusBadge } from '../components/StatusBadge.tsx'
import { useLoad } from '../state/useLoad.ts'
import { useWatch } from '../state/useWatch.ts'

// What no file shows, such as a run that died, is looked for now and then.
const REFRESH_MS = 30_000

const loadExecutions = () => listExecutions(transport)

export function ExecutionsPanel({
  state,
  dispatch,
}: {
  state: ShellState
  dispatch: Dispatch<Action>
}) {
  const { state: load, reload } = useLoad(loadExecutions, REFRESH_MS)
  useWatch('work', reload)
  return (
    <>
      <div className="panel-header">
        <h2 className="panel-title">Executions</h2>
        <button className="icon-button" aria-label="Refresh the list" onClick={reload}>
          <RefreshIcon />
        </button>
      </div>
      {load.status === 'loading' && <p className="panel-empty">Loading…</p>}
      {load.status === 'failed' && (
        <p className="panel-empty" role="alert">
          {load.error}
        </p>
      )}
      {load.status === 'ready' && load.data.length === 0 && (
        <>
          <p className="panel-empty">No executions found. A run starts from a pipeline's page.</p>
          <div className="panel-action">
            <button
              className="secondary"
              onClick={() => {
                dispatch({ type: 'selectDefinitionKind', kind: 'pipeline' })
                dispatch({ type: 'selectSection', section: 'definitions' })
              }}
            >
              Open the pipelines
            </button>
          </div>
        </>
      )}
      {load.status === 'ready' && (
        <div className="list">
          {load.data.map((run) => (
            <button
              key={run.id}
              className="list-item"
              aria-current={state.activeId === `execution:${run.id}` ? 'true' : undefined}
              onClick={() =>
                dispatch({ type: 'openPage', page: { kind: 'execution', id: run.id } })
              }
            >
              <span className="list-line">
                <span className="list-name">{run.pipeline ?? 'unknown pipeline'}</span>
                {waitingFor(run) !== null ? (
                  <span className="badge" data-status="waiting">
                    needs you
                  </span>
                ) : (
                  <StatusBadge status={run.status} />
                )}
              </span>
              <span className="list-note mono">
                {run.id}
                {run.currentStep !== null && ` · ${run.currentStep}`}
              </span>
            </button>
          ))}
        </div>
      )}
    </>
  )
}
