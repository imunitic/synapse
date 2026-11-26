import { useEffect, useRef, useState } from 'react'
import { readCleanupDays, writeCleanupDays } from '../domain/cleanup-days.ts'
import {
  planCleanup,
  runCleanup,
  runLabel,
  type CleanupChoice,
  type CleanupResult,
  type ExecutionSummary,
} from '../domain/executions.ts'
import { transport } from '../transport/index.ts'

// The numbers of days a person most often wants, one press each.
const PRESETS = [1, 7, 30]

// Past this many, the runs a clean up would remove are listed closed.
const OPEN_LIMIT = 5

type Preview =
  | { status: 'loading' }
  | { status: 'ready'; result: CleanupResult }
  | { status: 'failed'; error: string }

// The number of days in the field, when it is a whole number of at least 1.
function daysOf(text: string): number | null {
  if (!/^\d+$/.test(text.trim())) return null
  const days = Number(text.trim())
  return Number.isSafeInteger(days) && days >= 1 ? days : null
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// Removes the records of many runs at once: those older than a number of days, or every finished
// one. What would be removed is asked of the engine as a dry run whenever the choice changes, and
// shown before anything is removed. The number of days is remembered for the next time.
export function CleanupDialog({
  runs,
  onClose,
  onRemoved,
}: {
  // The runs the panel lists, to name the ones that would be removed.
  runs: ExecutionSummary[]
  onClose: () => void
  // The clean up is done and removed these runs.
  onRemoved: (removed: string[]) => void
}) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [kind, setKind] = useState<CleanupChoice['kind']>('olderThan')
  const [daysText, setDaysText] = useState(() => String(readCleanupDays(localStorage)))
  const [preview, setPreview] = useState<Preview>({ status: 'loading' })
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const days = daysOf(daysText)
  const choice: CleanupChoice | null =
    kind === 'all' ? { kind: 'all' } : days === null ? null : { kind: 'olderThan', days }

  useEffect(() => {
    dialog.current?.showModal()
  }, [])

  useEffect(() => {
    if (kind === 'olderThan' && days === null) return
    const asked: CleanupChoice =
      kind === 'all' ? { kind: 'all' } : { kind: 'olderThan', days: days ?? 1 }
    let current = true
    setPreview({ status: 'loading' })
    planCleanup(transport, asked)
      .then((result) => current && setPreview({ status: 'ready', result }))
      .catch(
        (failure: unknown) =>
          current && setPreview({ status: 'failed', error: messageOf(failure) }),
      )
    return () => {
      current = false
    }
  }, [kind, days])

  const removed = choice !== null && preview.status === 'ready' ? preview.result.removed : []

  async function remove() {
    if (choice === null) return
    setBusy(true)
    setError(null)
    try {
      const result = await runCleanup(transport, choice)
      if (days !== null) writeCleanupDays(localStorage, days)
      onRemoved(result.removed)
    } catch (failure) {
      setError(messageOf(failure))
      setBusy(false)
    }
  }

  function label(id: string): string {
    const run = runs.find((each) => each.id === id)
    return run === undefined ? id : runLabel(run).title
  }

  return (
    <dialog ref={dialog} className="dialog" aria-labelledby="cleanup-title" onClose={onClose}>
      <form
        onSubmit={(event) => {
          event.preventDefault()
          void remove()
        }}
      >
        <h2 id="cleanup-title" className="card-title">
          Clean up runs
        </h2>
        {/* The radio's label holds its words only, so that the field of days has a name of its own. */}
        <div className="check-row">
          <input
            id="cleanup-older"
            type="radio"
            name="cleanup-kind"
            checked={kind === 'olderThan'}
            onChange={() => setKind('olderThan')}
          />
          <label htmlFor="cleanup-older">Older than</label>
          <input
            type="text"
            inputMode="numeric"
            size={4}
            aria-label="Days"
            value={daysText}
            onChange={(event) => {
              setDaysText(event.target.value)
              setKind('olderThan')
            }}
          />
          <span>days</span>
        </div>
        <div className="row">
          {PRESETS.map((preset) => (
            <button
              key={preset}
              type="button"
              className="secondary"
              onClick={() => {
                setDaysText(String(preset))
                setKind('olderThan')
              }}
            >
              {preset === 1 ? '1 day' : `${preset} days`}
            </button>
          ))}
        </div>
        <label className="check-row">
          <input
            type="radio"
            name="cleanup-kind"
            checked={kind === 'all'}
            onChange={() => setKind('all')}
          />
          <span>Every finished run</span>
        </label>
        <p className="muted small">An interrupted run is kept until it is 30 days old.</p>
        {choice === null ? (
          <p className="muted">Enter a whole number of days, at least 1.</p>
        ) : preview.status === 'loading' ? (
          <p className="muted">Looking for runs to remove…</p>
        ) : preview.status === 'failed' ? (
          <p className="error" role="alert">
            {preview.error}
          </p>
        ) : removed.length === 0 ? (
          <p>Nothing to remove.</p>
        ) : (
          <details open={removed.length <= OPEN_LIMIT}>
            <summary>
              {removed.length === 1
                ? '1 run will be removed'
                : `${removed.length} runs will be removed`}
            </summary>
            <ul>
              {removed.map((id) => (
                <li key={id}>{label(id)}</li>
              ))}
            </ul>
          </details>
        )}
        {error !== null && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        <div className="row end dialog-actions">
          <button type="button" className="secondary" onClick={() => dialog.current?.close()}>
            Cancel
          </button>
          <button type="submit" className="danger" disabled={busy || removed.length === 0}>
            {busy ? 'Removing…' : 'Remove'}
          </button>
        </div>
      </form>
    </dialog>
  )
}
