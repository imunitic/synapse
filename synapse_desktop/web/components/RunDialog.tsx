import { useEffect, useRef, useState, type SubmitEvent } from 'react'
import { transport } from '../transport/index.ts'
import { PromptView } from './PromptView.tsx'

// The input of a run, as JSON, and the button that starts it. A native dialog
// gives the focus handling and the Escape key.
export function RunDialog({
  pipeline,
  firstStep,
  onClose,
  onStarted,
}: {
  pipeline: string
  // The step the input goes to, whose prompt can be looked at with the input in it.
  firstStep?: string
  onClose: () => void
  onStarted: (executionId: string) => void
}) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [text, setText] = useState('{}')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    dialog.current?.showModal()
  }, [])

  async function submit(event: SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    let input: unknown
    try {
      input = JSON.parse(text)
    } catch (parseError) {
      setError(`The input is not valid JSON: ${String(parseError)}`)
      return
    }
    setBusy(true)
    setError(null)
    try {
      const { executionId } = await transport.startRun(pipeline, input)
      onStarted(executionId)
    } catch (startError) {
      setError(`The run did not start: ${String(startError)}`)
      setBusy(false)
    }
  }

  return (
    <dialog ref={dialog} className="dialog" aria-labelledby="run-title" onClose={onClose}>
      <form onSubmit={(event) => void submit(event)}>
        <h2 id="run-title" className="card-title">
          Run <span className="mono">{pipeline}</span>
        </h2>
        <label htmlFor="run-input" className="muted">
          Input (JSON), handed to the first step
        </label>
        <textarea
          id="run-input"
          className="mono"
          rows={7}
          value={text}
          spellCheck={false}
          onChange={(event) => {
            setText(event.target.value)
            setError(null)
          }}
        />
        {firstStep !== undefined && (
          <PromptView
            pipeline={pipeline}
            step={firstStep}
            input={text}
            label="The prompt of the first step, with this input"
          />
        )}
        {error !== null && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        <div className="row end">
          <button type="button" className="secondary" onClick={() => dialog.current?.close()}>
            Cancel
          </button>
          <button type="submit" className="primary" disabled={busy}>
            {busy ? 'Starting…' : 'Start run'}
          </button>
        </div>
      </form>
    </dialog>
  )
}
