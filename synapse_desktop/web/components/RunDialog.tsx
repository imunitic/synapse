import { Fragment, useEffect, useMemo, useRef, useState, type SubmitEvent } from 'react'
import {
  checkProblems,
  fieldReference,
  sampleInput,
  takesText,
} from '../domain/input-declaration.ts'
import type { InputDeclaration } from '../domain/pipelines.ts'
import {
  interactiveProblem,
  previewInput,
  readFolder,
  runInput,
  writeFolder,
  type InputMode,
} from '../domain/run-input.ts'
import { transport } from '../transport/index.ts'
import { CodeEditor } from './CodeEditor.tsx'
import { DescribeRun } from './DescribeRun.tsx'
import { PencilIcon } from './icons.tsx'
import { PromptView } from './PromptView.tsx'
import { PathInput } from './PathInput.tsx'

// What a pipeline is to work on, as a sentence or as JSON, and the button that starts it. The
// settings of the run come before the prompt preview, which is closed until it is asked for, and the
// buttons stay in view however long the dialog gets. A native
// dialog gives the focus handling and the Escape key. A run starts on the terminal of the app, where
// a person can watch it and answer what its agents ask. Only a pipeline that cannot run that way, as
// `check --interactive` says, is started without a terminal, and the dialog says why. A pipeline that
// declares its input gets a sample to fill in, a reference of its fields, and its problems while they
// are typed; it starts only once there are none. Its JSON editor also has a pencil: a sentence that
// describes the run, from which an agent writes the JSON. That goes into the editor as one change
// that undo takes back, and is checked like anything typed; the agent never starts the run.

// How long the input has to stay the same before it is checked.
const checkDelayMs = 400

// No problems, and no edits to mark in the editor.
const noMarks: [] = []

export function RunDialog({
  pipeline,
  firstStep,
  firstStepPending,
  onClose,
  onStarted,
  onStartInteractive,
  defaultFolder,
  input: declared,
}: {
  pipeline: string
  // The step the input goes to, whose prompt can be looked at with the input in it.
  firstStep?: string
  // The first step is still being read; the preview says so until it is known.
  firstStepPending?: boolean
  onClose: () => void
  onStarted: (executionId: string) => void
  // An interactive run is started with this input, none when there is none, in this folder, with
  // this name when it was given one.
  onStartInteractive: (input: unknown, folder: string, runName?: string) => void
  // Where a run works unless it was told otherwise; empty is the home folder.
  defaultFolder: string
  // What the pipeline declares as its input: null when it declares none, undefined while the
  // pipeline is still being read.
  input?: InputDeclaration | null
}) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [mode, setMode] = useState<InputMode>('text')
  const [text, setText] = useState('')
  // The text the JSON editor starts with: a sample of the declared fields, or an empty object.
  const startJson = useMemo(() => (declared ? sampleInput(declared) : '{}'), [declared])
  const [json, setJson] = useState(startJson)
  // The text the JSON editor is given when it is shown: the editor is not there while the Text tab
  // is, so coming back to it must bring back what was typed, not the sample.
  const [editorStart, setEditorStart] = useState(startJson)
  const [startedWith, setStartedWith] = useState(startJson)
  if (startedWith !== startJson) {
    setStartedWith(startJson)
    setJson(startJson)
    setEditorStart(startJson)
  }
  // The describe box is open, and the text an agent wrote, given to the editor as one change.
  const [describing, setDescribing] = useState(false)
  const [filled, setFilled] = useState<{ id: number; text: string } | null>(null)
  // The answer of the last check, for the input it was asked about.
  const [check, setCheck] = useState<{ stdin: string; problems: string[] } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [folder, setFolder] = useState(() => readFolder(localStorage, pipeline, defaultFolder))
  // The run's name, empty each time the dialog opens: a name belongs to one run.
  const [name, setName] = useState('')
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

  // Until the check has answered it is not known how the run starts, so it cannot be started yet.
  const interactive = checked && problem === null

  // A sentence is offered only when the pipeline takes one; until that is known it is offered.
  const showText = declared === undefined || takesText(declared)
  const inputMode: InputMode = showText ? mode : 'json'
  const typed = runInput(inputMode, text, json)
  const stdin = typed.ok ? JSON.stringify(typed.value ?? null) : null
  const checking = declared !== undefined && declared !== null

  useEffect(() => {
    if (!checking || stdin === null) return
    let current = true
    const timer = setTimeout(() => {
      transport
        .cli('synapse-pipeline', ['check', pipeline, '--input', '-'], { stdin })
        .then((result) => current && setCheck({ stdin, problems: checkProblems(result) }))
        .catch(
          (failure: unknown) =>
            current &&
            setCheck({ stdin, problems: [`The input was not checked: ${String(failure)}`] }),
        )
    }, checkDelayMs)
    return () => {
      current = false
      clearTimeout(timer)
    }
  }, [checking, pipeline, stdin])

  // What is wrong with the input as it is now; a check of an earlier input does not count.
  const pending = checking && stdin !== null && check?.stdin !== stdin
  const inputProblems: string[] = !checking
    ? []
    : !typed.ok
      ? [typed.error]
      : check?.stdin === stdin
        ? check.problems
        : []
  const blocked = checking && (pending || inputProblems.length > 0)

  async function submit(event: SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!checked || blocked) return
    const input = runInput(inputMode, text, json)
    if (!input.ok) {
      setError(input.error)
      return
    }
    writeFolder(localStorage, pipeline, folder)
    const runName = name.trim() === '' ? undefined : name.trim()
    if (interactive) {
      onStartInteractive(input.value, folder.trim(), runName)
      return
    }
    setBusy(true)
    setError(null)
    try {
      const { executionId } = await transport.startRun(
        pipeline,
        input.value ?? null,
        folder.trim(),
        runName,
      )
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
        {showText && (
          <div className="subtabs" role="tablist" aria-label="Kind of input">
            <button
              type="button"
              role="tab"
              className="subtab"
              aria-selected={mode === 'text'}
              aria-pressed={mode === 'text'}
              onClick={() => {
                // The editor is mounted again on return, and would take the old fill again.
                setFilled(null)
                setMode('text')
              }}
            >
              Text
            </button>
            <button
              type="button"
              role="tab"
              className="subtab"
              aria-selected={mode === 'json'}
              aria-pressed={mode === 'json'}
              onClick={() => {
                if (mode !== 'json') setEditorStart(json)
                setMode('json')
              }}
            >
              JSON
            </button>
          </div>
        )}
        {inputMode === 'text' ? (
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
            <div className="row">
              <p className="muted">Input as JSON</p>
              {declared && (
                <button
                  type="button"
                  className="icon-button"
                  aria-label="Fill in with an agent"
                  title="Fill in with an agent"
                  aria-expanded={describing}
                  onClick={() => setDescribing(!describing)}
                >
                  <PencilIcon />
                </button>
              )}
            </div>
            {declared && describing && (
              <DescribeRun
                pipeline={pipeline}
                current={json}
                onFilled={(value) => {
                  setJson(value)
                  setError(null)
                  setFilled((last) => ({ id: (last?.id ?? 0) + 1, text: value }))
                }}
                onClose={() => setDescribing(false)}
              />
            )}
            <CodeEditor
              initial={editorStart}
              onChange={(value) => {
                setJson(value)
                setError(null)
              }}
              marks={noMarks}
              label="Input as JSON"
              language="json"
              replacement={filled}
            />
            {declared && (
              <dl className="facts small" aria-label="Fields of the input">
                {fieldReference(declared).map((field) => (
                  <Fragment key={field.name}>
                    <dt className="mono">{field.name}</dt>
                    <dd>
                      {field.type} · {field.required ? 'required' : 'optional'}{' '}
                      <span className="muted">{field.description}</span>
                    </dd>
                  </Fragment>
                ))}
              </dl>
            )}
          </>
        )}
        <div role="status" aria-label="Problems with the input">
          {inputProblems.length > 0 && (
            <ul className="problems">
              {inputProblems.map((p) => (
                <li key={p}>{p}</li>
              ))}
            </ul>
          )}
        </div>
        {checked && problem !== null && (
          <p className="muted small">
            This pipeline runs without a terminal, so nothing will ask you anything: {problem}
          </p>
        )}
        <label htmlFor="run-name" className="muted">
          Name (optional)
        </label>
        <input
          id="run-name"
          type="text"
          maxLength={120}
          value={name}
          placeholder="For example: Fix login"
          onChange={(event) => setName(event.target.value)}
        />
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
        {firstStep === undefined && firstStepPending === true && (
          <details className="prompt-view">
            <summary>The prompt of the first step, with this input</summary>
            <p className="muted">Building the prompt…</p>
          </details>
        )}
        {firstStep !== undefined && (
          <PromptView
            pipeline={pipeline}
            step={firstStep}
            input={previewInput(inputMode, text, json)}
            label="The prompt of the first step, with this input"
            interactive={interactive}
            openAdded
          />
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
          <button type="submit" className="primary" disabled={busy || !checked || blocked}>
            {busy ? 'Starting…' : 'Start run'}
          </button>
        </div>
      </form>
    </dialog>
  )
}
