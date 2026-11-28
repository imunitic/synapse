import { useCallback, useEffect, useState } from 'react'
import { describeStepPrompt, splitPrompt } from '../domain/pipelines.ts'
import { transport } from '../transport/index.ts'
import { useLoad } from '../state/useLoad.ts'

// A value that follows its source after it has stopped changing for a moment.
function useSettled<T>(value: T, ms: number): T {
  const [settled, setSettled] = useState(value)
  useEffect(() => {
    const timer = setTimeout(() => setSettled(value), ms)
    return () => clearTimeout(timer)
  }, [value, ms])
  return settled
}

function PromptText({
  pipeline,
  step,
  input,
  interactive,
  openAdded,
}: {
  pipeline: string
  step: string
  input: string | undefined
  interactive: boolean
  // Whether what the program adds shows from the start.
  openAdded: boolean
}) {
  const settled = useSettled(input, 300)
  const load = useCallback(
    () => describeStepPrompt(transport, pipeline, step, settled, interactive),
    [pipeline, step, settled, interactive],
  )
  const { state } = useLoad(load)
  if (state.status === 'loading') return <p className="muted">Building the prompt…</p>
  if (state.status === 'failed')
    return <p role="alert">Could not build the prompt: {state.error}</p>
  if (!state.data.ok) return <p className="muted">{state.data.message}</p>
  const { authored, added } = splitPrompt(state.data.parts)
  return (
    <>
      {authored === '' ? (
        <p className="muted">This step has no text of its own.</p>
      ) : (
        <pre className="mono prompt-text">{authored}</pre>
      )}
      <details className="prompt-added" open={openAdded}>
        <summary>
          Added by Synapse when it runs{' '}
          <span className="muted small">
            (the input, the result before, and how to report, from the step&apos;s outcomes)
          </span>
        </summary>
        <pre className="mono prompt-added-text">{added}</pre>
      </details>
    </>
  )
}

// The prompt a step is started with, built by the CLI as the runner builds it. Closed until
// it is asked for. With an input, the prompt holds it; after the first step it has a
// marked slot for what the step before reports.
export function PromptView({
  pipeline,
  step,
  input,
  label = 'The prompt',
  defaultOpen = false,
  interactive = false,
  openAdded = false,
}: {
  pipeline: string
  step: string
  input?: string
  label?: string
  // Open from the start, which is for where the prompt is what the person is deciding on.
  defaultOpen?: boolean
  // The prompt of a step that runs on a terminal, where a person can answer.
  interactive?: boolean
  // Open what the program adds, which is where the input shows.
  openAdded?: boolean
}) {
  const [open, setOpen] = useState(defaultOpen)
  return (
    <details
      className="prompt-view"
      open={defaultOpen}
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary>{label}</summary>
      {open && (
        <PromptText
          pipeline={pipeline}
          step={step}
          input={input}
          interactive={interactive}
          openAdded={openAdded}
        />
      )}
    </details>
  )
}
