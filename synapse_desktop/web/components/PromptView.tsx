import { useCallback, useEffect, useState } from 'react'
import { describeStepPrompt } from '../domain/pipelines.ts'
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
}: {
  pipeline: string
  step: string
  input: string | undefined
}) {
  const settled = useSettled(input, 300)
  const load = useCallback(
    () => describeStepPrompt(transport, pipeline, step, settled),
    [pipeline, step, settled],
  )
  const { state } = useLoad(load)
  if (state.status === 'loading') return <p className="muted">Building the prompt…</p>
  if (state.status === 'failed')
    return <p role="alert">Could not build the prompt: {state.error}</p>
  if (!state.data.ok) return <p className="muted">{state.data.message}</p>
  return <pre className="source mono prompt-text">{state.data.prompt}</pre>
}

// The prompt a step is started with, built by the CLI as the runner builds it. Closed until
// it is asked for. With an input, the prompt holds it; after the first step it has a
// marked slot for what the step before reports.
export function PromptView({
  pipeline,
  step,
  input,
  label = 'The prompt',
}: {
  pipeline: string
  step: string
  input?: string
  label?: string
}) {
  const [open, setOpen] = useState(false)
  return (
    <details className="prompt-view" onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary>{label}</summary>
      {open && <PromptText pipeline={pipeline} step={step} input={input} />}
    </details>
  )
}
