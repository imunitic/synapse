import { useState } from 'react'
import type { NoteStatus } from '../../shared/messages.ts'
import { transport } from '../transport/index.ts'
import { CheckCircleFilledIcon, CheckCircleIcon } from './icons.tsx'

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// Marking a task note as done, a check among the tools of the note's page. Only a person does it: an
// agent that changes a note is told never to set DONE, so it is not asked of one. The program sets the
// status itself. Once marked the check is filled, and pressing it puts the status that was there back.
export function TaskStatus({
  path,
  status,
  onChanged,
}: {
  path: string
  // The status the note has now.
  status: string
  onChanged: () => void
}) {
  // The status it had before it was marked, while the person can still undo that.
  const [marked, setMarked] = useState<{ before: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function set(next: NoteStatus, then: { before: string } | null) {
    setBusy(true)
    setError(null)
    try {
      await transport.setNoteStatus(path, next)
      setMarked(then)
      onChanged()
    } catch (failure) {
      setError(messageOf(failure))
    } finally {
      setBusy(false)
    }
  }

  const label =
    marked !== null ? 'Undo marking as done' : status === 'DONE' ? 'Done' : 'Mark as done'
  return (
    <>
      <button
        className={status === 'DONE' || marked !== null ? 'icon-button task-done' : 'icon-button'}
        aria-label={label}
        title={label}
        aria-pressed={status === 'DONE' || marked !== null}
        disabled={busy || (status === 'DONE' && marked === null)}
        onClick={() =>
          marked !== null
            ? void set(marked.before as NoteStatus, null)
            : void set('DONE', { before: status })
        }
      >
        {status === 'DONE' || marked !== null ? <CheckCircleFilledIcon /> : <CheckCircleIcon />}
      </button>
      {error !== null && (
        <span className="note-tool-error small" role="alert" title={error}>
          The status was not set: {error}
        </span>
      )}
    </>
  )
}
