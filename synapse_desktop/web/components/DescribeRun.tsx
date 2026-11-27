import { useEffect, useRef, useState, type KeyboardEvent } from 'react'
import { transport } from '../transport/index.ts'
import { RunChoice, useRunChoice } from './RunChoice.tsx'
import { WorkingLine, useRun } from './WorkingLine.tsx'

// Describe a run in a sentence and have an agent write its input as JSON. The agent may only read
// the vault; what it writes goes into the editor, to be checked like anything typed, and the run
// starts only when Start run is pressed. The card sits inside the run form, so none of its buttons
// submits it, and Enter in the box fills in instead of starting the run.
export function DescribeRun({
  pipeline,
  current,
  onFilled,
  onClose,
}: {
  pipeline: string
  // The JSON in the editor now, which the description may add to.
  current: string
  onFilled: (text: string) => void
  onClose: () => void
}) {
  const [prompt, setPrompt] = useState('')
  const { harness, model, chooseHarness, chooseModel } = useRunChoice()
  const [working, setWorking] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const run = useRun()
  // The run in progress, while the card is open. Closing the card stops it, and its answer, which
  // may still come, no longer reaches the editor.
  const pending = useRef<string | null>(null)
  useEffect(
    () => () => {
      const runId = pending.current
      pending.current = null
      if (runId === null) return
      transport.stopAgentRun(runId).catch(() => {
        // The run ends through its own call; nobody waits for it any more.
      })
    },
    [],
  )

  async function fillIn() {
    if (working || prompt.trim() === '') return
    setWorking(true)
    setFailure(null)
    const runId = run.begin()
    pending.current = runId
    try {
      const { text } = await transport.fillRunInput({
        run: runId,
        pipeline,
        prompt,
        harness,
        ...(model === null ? {} : { model }),
        current,
      })
      if (pending.current !== runId) return
      onFilled(text)
      setPrompt('')
      onClose()
    } catch (error) {
      if (pending.current !== runId) return
      setFailure(String(error))
    } finally {
      if (pending.current === runId) {
        pending.current = null
        setWorking(false)
        run.end()
      }
    }
  }

  function handleKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key !== 'Enter') return
    event.preventDefault()
    void fillIn()
  }

  return (
    <section className="card agent-card" aria-label="Describe this run">
      <label className="field">
        <span>Describe this run</span>
        <input
          type="text"
          value={prompt}
          disabled={working}
          placeholder="For example: the design note about cloning pipelines"
          onChange={(event) => setPrompt(event.target.value)}
          onKeyDown={handleKeyDown}
        />
      </label>
      <div className="row">
        <RunChoice
          harness={harness}
          model={model}
          onHarness={chooseHarness}
          onModel={chooseModel}
          disabled={working}
        />
        <button
          type="button"
          className="primary"
          disabled={working || prompt.trim() === ''}
          onClick={() => void fillIn()}
        >
          {working ? 'Filling in…' : 'Fill in'}
        </button>
      </div>
      {working && run.startedAt !== null && (
        <WorkingLine
          harness={harness}
          startedAt={run.startedAt}
          doing="filling in the input"
          stopping={run.stopping}
          onStop={run.stop}
        />
      )}
      {failure !== null && (
        <p className="error" role="alert">
          {failure}
        </p>
      )}
    </section>
  )
}
