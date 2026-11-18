import { useState } from 'react'
import type { Harness } from '../../shared/transport.ts'
import { useConfig } from '../state/config.tsx'
import { useHarnesses } from '../state/diagnosis.tsx'
import { TERMINAL_LABELS } from '../state/state.ts'
import { ModelPicker } from './ModelPicker.tsx'

const HARNESSES: readonly Harness[] = ['Claude', 'Codex', 'Opencode']

// What a run of an agent is asked to use. It begins as the settings say: the default harness, and
// that harness's default model. A choice made here is for this run only, and another harness has
// other models, so choosing one drops the choice of a model.
export function useRunChoice(): {
  harness: Harness
  // The model chosen for this run, or null while it is the default of the harness.
  model: string | null
  chooseHarness: (harness: Harness) => void
  chooseModel: (model: string | null) => void
} {
  const { defaultHarness } = useHarnesses()
  const [chosenHarness, setChosenHarness] = useState<Harness | null>(null)
  const [model, setModel] = useState<string | null>(null)
  return {
    harness: chosenHarness ?? defaultHarness,
    model,
    chooseHarness: (harness) => {
      setChosenHarness(harness)
      setModel(null)
    },
    chooseModel: setModel,
  }
}

// The harness and the model of a run, in one row.
export function RunChoice({
  harness,
  model,
  onHarness,
  onModel,
  disabled = false,
}: {
  harness: Harness
  model: string | null
  onHarness: (harness: Harness) => void
  onModel: (model: string | null) => void
  disabled?: boolean
}) {
  const harnesses = useHarnesses()
  const { state } = useConfig()
  const saved = state.status === 'ready' ? state.config.defaultModels[harness] : undefined
  // Going back to the default shows it again, which the box does not know to do by itself.
  const [again, setAgain] = useState(0)
  return (
    <div className="run-choice">
      <label className="run-choice-part">
        <span className="muted small">Harness</span>
        <select
          aria-label="Harness for this run"
          value={harness}
          disabled={disabled}
          onChange={(event) => onHarness(event.target.value as Harness)}
        >
          {HARNESSES.map((h) => (
            <option key={h} value={h} disabled={harnesses.isMissing(h)}>
              {TERMINAL_LABELS[h]}
              {harnesses.isMissing(h) ? ' (not installed)' : ''}
            </option>
          ))}
        </select>
      </label>
      <div className="run-choice-part">
        <span className="muted small">Model</span>
        <ModelPicker
          // Another harness has another list, and a new picker reads it.
          key={`${harness}:${again}`}
          harness={harness}
          label="Model for this run"
          // The default of the harness is what is shown until another is chosen.
          value={model ?? saved ?? null}
          onChange={(next) => {
            if (next === null || next === saved) setAgain((n) => n + 1)
            onModel(next === saved ? null : next)
          }}
          clearable={model !== null}
          clearLabel="Back to the default"
          disabled={disabled}
          placeholder="The harness chooses"
        />
      </div>
    </div>
  )
}
