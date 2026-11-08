import { useMemo, useState } from 'react'
import type { NoteEdit } from '../../shared/transport.ts'
import { changeCount, diffLines, withContext } from '../domain/diff.ts'
import { transport } from '../transport/index.ts'
import { useHarnesses } from '../state/diagnosis.tsx'
import { PencilIcon } from './icons.tsx'
import { TERMINAL_LABELS } from '../state/state.ts'

// What a change left, to be read and undone: the lines it added and removed, the other
// notes that moved, which it should not have, and a way to put the note back.
function Result({
  path,
  edit,
  onChanged,
}: {
  path: string
  edit: NoteEdit
  onChanged: () => void
}) {
  const lines = useMemo(() => diffLines(edit.before, edit.after), [edit])
  const { added, removed } = changeCount(lines)
  const [state, setState] = useState<'edited' | 'restoring' | 'restored'>('edited')
  const [problem, setProblem] = useState<string | null>(null)

  async function restore() {
    setState('restoring')
    setProblem(null)
    try {
      await transport.restoreNote(path, edit.before, edit.after)
      setState('restored')
      onChanged()
    } catch (error) {
      setProblem(String(error).replace(/^Error: /, ''))
      setState('edited')
    }
  }

  return (
    <section className="card edit-result" aria-label="What the change did">
      <p role="status">
        {state === 'restored'
          ? 'The note is put back as it was.'
          : `The note is changed: ${added} ${added === 1 ? 'line' : 'lines'} added and ${removed} removed.`}
      </p>
      {edit.touched.length > 0 && (
        <p className="warn-line" role="alert">
          The agent also moved {edit.touched.length === 1 ? 'another note' : 'other notes'}, which
          it was told not to: <span className="mono small">{edit.touched.join(', ')}</span>
        </p>
      )}
      {state !== 'restored' && (
        <details>
          <summary>Show what changed</summary>
          <pre className="diff" aria-label="The lines that changed">
            {withContext(lines, 2).map((line, i) =>
              line.kind === 'gap' ? (
                <div key={i} className="diff-line diff-gap">
                  … {line.hidden} unchanged {line.hidden === 1 ? 'line' : 'lines'}
                </div>
              ) : (
                <div key={i} className={`diff-line diff-${line.kind}`}>
                  {line.kind === 'added' ? '+ ' : line.kind === 'removed' ? '- ' : '  '}
                  {line.text}
                </div>
              ),
            )}
          </pre>
        </details>
      )}
      {state !== 'restored' && (
        <div className="row">
          <button
            className="secondary"
            disabled={state === 'restoring'}
            onClick={() => void restore()}
          >
            {state === 'restoring' ? 'Putting it back…' : 'Undo'}
          </button>
        </div>
      )}
      {problem !== null && (
        <p className="error" role="alert">
          {problem}
        </p>
      )}
    </section>
  )
}

// Ask an agent to change this note, as the New note page asks one to write a note.
// The pencil opens the box; when the agent has changed the note it is read again, and
// what the change did is shown with a way to undo it.
export function EditNote({
  path,
  title,
  onChanged,
}: {
  path: string
  // The note's title, which the pencil sits beside.
  title: string
  onChanged: () => void
}) {
  const { defaultHarness: harness } = useHarnesses()
  const [open, setOpen] = useState(false)
  const [prompt, setPrompt] = useState('')
  const [working, setWorking] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const [edit, setEdit] = useState<NoteEdit | null>(null)

  async function change() {
    setWorking(true)
    setFailure(null)
    setEdit(null)
    try {
      const result = await transport.editNote({ path, prompt, harness })
      setEdit(result)
      setPrompt('')
      setOpen(false)
      onChanged()
    } catch (error) {
      setFailure(String(error).replace(/^Error: /, ''))
    } finally {
      setWorking(false)
    }
  }

  function cancel() {
    setOpen(false)
    setPrompt('')
    setFailure(null)
  }

  return (
    <>
      <div className="note-head">
        <h1 className="page-title">{title}</h1>
        <button
          className="icon-button edit-note-button"
          aria-label="Edit with an agent"
          aria-expanded={open}
          onClick={() => setOpen(!open)}
        >
          <PencilIcon />
        </button>
      </div>
      {open && (
        <section className="card agent-card" aria-label="Change this note with an agent">
          <label className="field">
            <span>What should change?</span>
            <textarea
              rows={4}
              value={prompt}
              disabled={working}
              onChange={(event) => setPrompt(event.target.value)}
              placeholder="For example: tick the first item and add a note about why."
            />
          </label>
          <p className="muted small">
            {TERMINAL_LABELS[harness]} changes this note with Synapse&apos;s skills and shows what
            it did, which you can undo. It is told to change only this note.
          </p>
          <div className="row">
            <button
              className="primary"
              disabled={working || prompt.trim() === ''}
              onClick={() => void change()}
            >
              {working ? 'Changing…' : 'Change the note'}
            </button>
            <button className="secondary" disabled={working} onClick={cancel}>
              Cancel
            </button>
            {working && (
              <span className="muted small" role="status">
                An agent is changing it, this can take a few minutes.
              </span>
            )}
          </div>
          {failure !== null && (
            <p className="error" role="alert">
              {failure}
            </p>
          )}
        </section>
      )}
      {edit !== null && <Result path={path} edit={edit} onChanged={onChanged} />}
    </>
  )
}
