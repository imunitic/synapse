import { useCallback } from 'react'
import { describePipeline } from '../domain/pipelines.ts'
import { transport } from '../transport/index.ts'
import { useConfig } from '../state/config.tsx'
import { useLoad } from '../state/useLoad.ts'
import { RunDialog } from '../components/RunDialog.tsx'

// The run dialog of a pipeline opened from outside its page. It reads the pipeline for the first
// step's prompt preview and its declared input; the dialog works while that is pending, and
// without them when the pipeline cannot be read or has problems.
export function RunDialogHost({
  pipeline,
  onClose,
  onStarted,
  onStartInteractive,
}: {
  pipeline: string
  onClose: () => void
  onStarted: (executionId: string) => void
  onStartInteractive: (input: unknown, folder: string, runName?: string) => void
}) {
  const load = useCallback(() => describePipeline(transport, pipeline), [pipeline])
  const { state } = useLoad(load)
  const { state: config } = useConfig()

  const firstStep =
    state.status === 'ready' && state.data.ok ? state.data.description.steps[0]?.name : undefined
  // The declared input, null when there is none or the pipeline cannot be read.
  const input =
    state.status === 'loading'
      ? undefined
      : state.status === 'ready' && state.data.ok
        ? state.data.description.input
        : null

  return (
    <RunDialog
      pipeline={pipeline}
      firstStep={firstStep}
      firstStepPending={state.status === 'loading'}
      input={input}
      onClose={onClose}
      onStarted={onStarted}
      onStartInteractive={onStartInteractive}
      defaultFolder={config.status === 'ready' ? (config.config.terminalFolder ?? '') : ''}
    />
  )
}
