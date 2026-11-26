import { useEffect, useState, type Dispatch } from 'react'
import {
  DELETE_ONE_CONFIRM,
  keptReasonText,
  listExecutions,
  removeExecutions,
  runLabel,
  waitingFor,
  type CleanupResult,
  type ExecutionSummary,
} from '../domain/executions.ts'
import { transport } from '../transport/index.ts'
import { RefreshIcon, TrashIcon } from '../components/icons.tsx'
import type { Action, ShellState } from '../state/state.ts'
import { StatusBadge } from '../components/StatusBadge.tsx'
import { CleanupDialog } from '../components/CleanupDialog.tsx'
import { useLoad } from '../state/useLoad.ts'
import { useWatch } from '../state/useWatch.ts'
import { forgetGoneRuns } from '../state/run-repositories.ts'

// What no file shows, such as a run that died, is looked for now and then.
const REFRESH_MS = 30_000

function deleteMany(count: number): string {
  return `Delete the records of ${count} runs? Their transcripts, patches and outcomes are removed. The changes they made in the repository stay.`
}

// The pins of the repositories added to a run whose record is gone are deleted with it. With no
// work directory nothing is listed, and nothing is taken for gone; nor when the work directory
// changed while the list was read.
async function loadExecutions() {
  const { recordsDir } = await transport.getPaths()
  const listed = await listExecutions(transport)
  const after = await transport.getPaths()
  void forgetGoneRuns(
    transport,
    after.recordsDir === recordsDir ? recordsDir : null,
    listed.map((one) => one.id),
  )
  return listed
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// The runs a removal kept, named as the list shows them, or null when it kept none.
function keptMessage(kept: CleanupResult['kept'], runs: ExecutionSummary[]): string | null {
  if (kept.length === 0) return null
  const named = kept.map((one) => {
    const run = runs.find((each) => each.id === one.id)
    const label = run === undefined ? one.id : runLabel(run).title
    return `${label} (${keptReasonText(one.reason)})`
  })
  return `Not removed: ${named.join(', ')}`
}

// The ids of the runs that can be deleted: every one that is not running.
function deletable(runs: ExecutionSummary[]): string[] {
  return runs.filter((run) => run.status !== 'running').map((run) => run.id)
}

export function ExecutionsPanel({
  state,
  dispatch,
}: {
  state: ShellState
  dispatch: Dispatch<Action>
}) {
  const { state: load, reload } = useLoad(loadExecutions, REFRESH_MS)
  useWatch('work', reload)
  const [problem, setProblem] = useState<string | null>(null)
  // The runs ticked in selection mode, or null when the panel is not in it.
  const [selected, setSelected] = useState<Set<string> | null>(null)
  const selecting = selected !== null
  const [cleaning, setCleaning] = useState(false)

  useEffect(() => {
    if (!selecting) return
    function onKey(event: KeyboardEvent) {
      if (event.key === 'Escape') setSelected(null)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [selecting])

  function toggle(id: string) {
    setSelected((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  async function remove(ids: string[], runs: ExecutionSummary[]) {
    setProblem(null)
    try {
      const result = await removeExecutions(transport, ids)
      dispatch({ type: 'executionsRemoved', ids: result.removed })
      setProblem(keptMessage(result.kept, runs))
    } catch (error) {
      setProblem(messageOf(error))
    }
    reload()
  }

  return (
    <>
      <div className="panel-header">
        <h2 className="panel-title">Executions</h2>
        <div className="row">
          {!selecting && (
            <>
              <button className="subtab" onClick={() => setSelected(new Set())}>
                Select
              </button>
              <button className="subtab" onClick={() => setCleaning(true)}>
                Clean up
              </button>
            </>
          )}
          <button className="icon-button" aria-label="Refresh the list" onClick={reload}>
            <RefreshIcon />
          </button>
        </div>
      </div>
      {selected !== null && (
        <div className="head-actions panel-action">
          <span className="muted small">{selected.size} selected</span>
          <button
            className="subtab"
            onClick={() => {
              const finished = load.status === 'ready' ? deletable(load.data) : []
              const all = finished.length > 0 && finished.every((id) => selected.has(id))
              setSelected(all ? new Set() : new Set(finished))
            }}
          >
            Select all
          </button>
          <button
            className="danger"
            disabled={selected.size === 0}
            onClick={() => {
              if (!window.confirm(deleteMany(selected.size))) return
              const runs = load.status === 'ready' ? load.data : []
              setSelected(null)
              void remove([...selected], runs)
            }}
          >
            Delete {selected.size}
          </button>
          <button className="subtab" onClick={() => setSelected(null)}>
            Cancel
          </button>
        </div>
      )}
      {cleaning && (
        <CleanupDialog
          runs={load.status === 'ready' ? load.data : []}
          onClose={() => setCleaning(false)}
          onRemoved={(removed) => {
            dispatch({ type: 'executionsRemoved', ids: removed })
            setCleaning(false)
            reload()
          }}
        />
      )}
      {problem !== null && (
        <p className="panel-empty" role="alert">
          {problem}
        </p>
      )}
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
          {load.data.map((run) => {
            const label = runLabel(run)
            const step = run.currentStep !== null ? ` · ${run.currentStep}` : ''
            return (
              <div key={run.id} className="list-row">
                {selected !== null && (
                  <input
                    type="checkbox"
                    aria-label={`Select ${label.title}`}
                    disabled={run.status === 'running'}
                    checked={selected.has(run.id)}
                    onChange={() => toggle(run.id)}
                  />
                )}
                <button
                  className="list-item"
                  aria-current={state.activeId === `execution:${run.id}` ? 'true' : undefined}
                  onClick={() => {
                    if (selected === null)
                      dispatch({ type: 'openPage', page: { kind: 'execution', id: run.id } })
                    else if (run.status !== 'running') toggle(run.id)
                  }}
                >
                  <span className="list-line">
                    <span className="list-name">{label.title}</span>
                    {run.interactive !== null && (
                      <span className="muted small">
                        {run.interactive ? 'interactive' : 'autonomous'}
                      </span>
                    )}
                    {waitingFor(run) !== null ? (
                      <span className="badge" data-status="waiting">
                        needs you
                      </span>
                    ) : (
                      <StatusBadge status={run.status} />
                    )}
                  </span>
                  {label.note !== null ? (
                    <span className="list-note">
                      {label.note}
                      {step}
                    </span>
                  ) : (
                    <span className="list-note mono">
                      {run.id}
                      {step}
                    </span>
                  )}
                </button>
                {selected === null && run.status !== 'running' && (
                  <button
                    className="icon-button list-action"
                    aria-label="Delete this run"
                    title="Delete this run"
                    onClick={() => {
                      if (window.confirm(DELETE_ONE_CONFIRM)) void remove([run.id], load.data)
                    }}
                  >
                    <TrashIcon />
                  </button>
                )}
              </div>
            )
          })}
        </div>
      )}
    </>
  )
}
