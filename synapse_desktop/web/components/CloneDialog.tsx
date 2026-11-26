import { useEffect, useRef, useState } from 'react'
import { clonePipelineText, cloneName, cloneNameProblem } from '../domain/clone.ts'
import { listDefinitions, type DefinitionKind } from '../domain/definitions.ts'
import { previewDraft } from '../domain/drafts.ts'
import type { Problem } from '../domain/pipelines.ts'
import { transport } from '../transport/index.ts'

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// Copies a pipeline under a new name. The name is checked as it is typed, and the copy's text is
// checked by the engine before it is written: a copy the engine refuses is not written.
export function CloneDialog({
  name,
  path,
  onClose,
  onCloned,
}: {
  // The pipeline to copy, and its file.
  name: string
  path: string
  onClose: () => void
  // The copy is written: its name and its file.
  onCloned: (name: string, path: string) => void
}) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [copy, setCopy] = useState(() => cloneName(name))
  const [existing, setExisting] = useState<{ name: string; kind: DefinitionKind }[]>([])
  const [problems, setProblems] = useState<Problem[]>([])
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    dialog.current?.showModal()
  }, [])

  useEffect(() => {
    let current = true
    listDefinitions(transport)
      .then(
        (definitions) =>
          current && setExisting(definitions.map((d) => ({ name: d.name, kind: d.kind }))),
      )
      .catch((failure: unknown) => current && setError(messageOf(failure)))
    return () => {
      current = false
    }
  }, [])

  const nameProblem = cloneNameProblem(copy, existing)

  async function clone() {
    if (nameProblem !== null) return
    setBusy(true)
    setError(null)
    setProblems([])
    try {
      const text = clonePipelineText(await transport.readText(path), name, copy)
      const preview = await previewDraft(transport, text, { kind: 'pipeline', name: copy })
      if (preview.problems.length > 0) {
        setProblems(preview.problems)
        setBusy(false)
        return
      }
      const written = await transport.writeDefinition({ kind: 'definition', name: copy, text })
      onCloned(copy, written.path)
    } catch (failure) {
      setError(messageOf(failure))
      setBusy(false)
    }
  }

  return (
    <dialog ref={dialog} className="dialog" aria-labelledby="clone-title" onClose={onClose}>
      <form
        onSubmit={(event) => {
          event.preventDefault()
          void clone()
        }}
      >
        <h2 id="clone-title" className="card-title">
          Clone {name}
        </h2>
        <label htmlFor="clone-name" className="muted">
          Name
        </label>
        <input
          id="clone-name"
          type="text"
          className="mono"
          value={copy}
          onChange={(event) => {
            setCopy(event.target.value)
            setProblems([])
          }}
        />
        {nameProblem !== null && (
          <p className="error" role="alert">
            {nameProblem}
          </p>
        )}
        {problems.length > 0 && (
          <section className="alert" role="alert" aria-label="Problems">
            <p>The copy cannot be written:</p>
            <ul className="problems mono">
              {problems.map((p, i) => (
                <li key={i}>{p.message}</li>
              ))}
            </ul>
          </section>
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
          <button type="submit" className="primary" disabled={busy || nameProblem !== null}>
            {busy ? 'Cloning…' : 'Clone'}
          </button>
        </div>
      </form>
    </dialog>
  )
}
