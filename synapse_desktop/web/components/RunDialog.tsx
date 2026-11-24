import { useEffect, useRef, useState, type SubmitEvent } from 'react'
import {
  interactiveProblem,
  previewInput,
  readFolder,
  readAutonomous,
  runInput,
  writeFolder,
  writeAutonomous,
  type InputMode,
} from '../domain/run-input.ts'
import { transport } from '../transport/index.ts'
import { PromptView } from './PromptView.tsx'
import { PathInput } from './PathInput.tsx'

// What a pipeline is to work on, as a sentence or as JSON, and the button that starts it. A native
// dialog gives the focus handling and the Escape key. A run can be started on the terminal of the
// app, where a person can watch it and answer what its agents ask.
export function RunDialog({
  pipeline,
  firstStep,
  onClose,
  onStarted,
  onStartInteractive,
  defaultFolder,
}: {
  pipeline: string
  // The step the input goes to, whose prompt can be looked at with the input in it.
  firstStep?: string
  onClose: () => void
  onStarted: (executionId: string) => void
  // An interactive run is started with this input, none when there is none, in this folder.
  onStartInteractive: (input: unknown, folder: string) => void
  // Where an interactive run works unless it was told otherwise; empty is the home folder.
  defaultFolder: string
}) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [mode, setMode] = useState<InputMode>('text')
  const [text, setText] = useState('')
  const [json, setJson] = useState('{}')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [autonomous, setAutonomous] = useState(() => readAutonomous(localStorage, pipeline))
  const [folder, setFolder] = useState(() => readFolder(localStorage, pipeline, defaultFolder))
  // Why the pipeline cannot be run interactively, once that is known.
  const [problem, setProblem] = useState<string | null>(null)
  const [checked, setChecked] = useState(false)

  useEffect(() => {
    dialog.current?.showModal()
  }, [])

  useEffect(() => {
    let current = true
    transport
      .cli('synapse-pipeline', ['check', pipeline, '--interactive'])
      .then((result) => current && setProblem(interactiveProblem(result)))
      .catch((failure: unknown) => current && setProblem(String(failure)))
      .finally(() => current && setChecked(true))
    return () => {
      current = false
    }
  }, [pipeline])

  const canBeInteractive = checked && problem === null
  const wantsInteractive = canBeInteractive && !autonomous

  async function submit(event: SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    const input = runInput(mode, text, json)
    if (!input.ok) {
      setError(input.error)
      return
    }
    if (wantsInteractive) {
      writeFolder(localStorage, pipeline, folder)
      onStartInteractive(input.value, folder.trim())
      return
    }
    setBusy(true)
    setError(null)
    try {
      const { executionId } = await transport.startRun(pipeline, input.value ?? null)
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
        <div className="subtabs" role="tablist" aria-label="Kind of input">
          <button
            type="button"
            role="tab"
            className="subtab"
            aria-selected={mode === 'text'}
            aria-pressed={mode === 'text'}
            onClick={() => setMode('text')}
          >
            Text
          </button>
          <button
            type="button"
            role="tab"
            className="subtab"
            aria-selected={mode === 'json'}
            aria-pressed={mode === 'json'}
            onClick={() => setMode('json')}
          >
            JSON
          </button>
        </div>
        {mode === 'text' ? (
          <>
            <label htmlFor="run-input" className="muted">
              What should this pipeline work on?
            </label>
            <textarea
              id="run-input"
              rows={5}
              value={text}
              placeholder="For example: Add a --verbose flag to the command line"
              onChange={(event) => {
                setText(event.target.value)
                setError(null)
              }}
            />
          </>
        ) : (
          <>
            <label htmlFor="run-input" className="muted">
              Input as JSON, handed to the first step as it is
            </label>
            <textarea
              id="run-input"
              className="mono"
              rows={7}
              value={json}
              spellCheck={false}
              onChange={(event) => {
                setJson(event.target.value)
                setError(null)
              }}
            />
          </>
        )}
        {firstStep !== undefined && (
          <PromptView
            pipeline={pipeline}
            step={firstStep}
            input={previewInput(mode, text, json)}
            label="The prompt of the first step, with this input"
            defaultOpen
            interactive={wantsInteractive}
            openAdded
          />
        )}
        <label className="check-row" htmlFor="run-autonomous">
          <input
            id="run-autonomous"
            type="checkbox"
            checked={autonomous || !canBeInteractive}
            disabled={!canBeInteractive}
            onChange={(event) => {
              setAutonomous(event.target.checked)
              writeAutonomous(localStorage, pipeline, event.target.checked)
            }}
          />
          <span>Run without a terminal: nothing will ask me anything</span>
        </label>
        {checked && problem !== null && <p className="muted small">{problem}</p>}
        {wantsInteractive && (
          <>
            <label htmlFor="run-folder" className="muted">
              Folder its agents work in (empty is your home folder)
            </label>
            <PathInput
              id="run-folder"
              className="mono"
              value={folder}
              placeholder="/path/to/a/project"
              onChange={setFolder}
            />
          </>
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
