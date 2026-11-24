import { useEffect, useState } from 'react'
import type { Harness } from '../../shared/transport.ts'
import { formatElapsed } from '../domain/note-run.ts'
import { TERMINAL_LABELS } from '../state/state.ts'
import { transport } from '../transport/index.ts'

// The run of a page that does not keep it in `note-edits.ts`: its id, when it began, and Stop.
export interface RunHandle {
  run: string | null
  startedAt: number | null
  stopping: boolean
  // Makes the id and the start time; the id goes on the request.
  begin(): string
  // Asks the host to end the run.
  stop(): void
  // The run is over.
  end(): void
}

export function useRun(): RunHandle {
  const [state, setState] = useState<{
    run: string | null
    startedAt: number | null
    stopping: boolean
  }>({ run: null, startedAt: null, stopping: false })

  function begin(): string {
    const run = crypto.randomUUID()
    setState({ run, startedAt: Date.now(), stopping: false })
    return run
  }

  function stop() {
    if (state.run === null || state.stopping) return
    setState({ ...state, stopping: true })
    transport.stopAgentRun(state.run).catch(() => {
      // The run ends through its own call, with its own result or failure.
    })
  }

  function end() {
    setState({ run: null, startedAt: null, stopping: false })
  }

  return { ...state, begin, stop, end }
}

// The line that shows an agent at work: who, doing what, for how long, and a way to stop it.
export function WorkingLine({
  harness,
  startedAt,
  doing,
  action = null,
  stopping,
  onStop,
}: {
  harness: Harness
  startedAt: number
  // "changing the note", "writing the note", "writing the text"
  doing: string
  action?: string | null
  stopping: boolean
  onStop: () => void
}) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [])

  return (
    <div className="working-line" role="status">
      <span className="spinner" aria-hidden="true" />
      <span>
        {TERMINAL_LABELS[harness]} is {doing} · {formatElapsed(Math.max(0, now - startedAt))}
      </span>
      {action !== null && <span className="muted small working-action">{action}</span>}
      <button className="secondary" disabled={stopping} onClick={onStop}>
        {stopping ? 'Stopping…' : 'Stop'}
      </button>
    </div>
  )
}
