import { useState } from 'react'
import type { Harness } from '../../shared/transport.ts'
import { useConfig } from '../state/config.tsx'
import { useHarnesses } from '../state/diagnosis.tsx'
import { TERMINAL_LABELS } from '../state/state.ts'
import { EffortPicker } from './EffortPicker.tsx'
import { ModelPicker } from './ModelPicker.tsx'

const HARNESSES: readonly Harness[] = ['Claude', 'Codex', 'Opencode']

// What a run of an agent is asked to use. It begins as the settings say: the default harness, and
// that harness's default model and effort. A choice made here is for this run only, and another
// harness has other models and efforts, so choosing one drops the choice of both.
export function useRunChoice(): {
  harness: Harness
  // The model chosen for this run, or null while it is the default of the harness.
  model: string | null
  // The effort chosen for this run, or null while it is the default of the harness.
  effort: string | null
  chooseHarness: (harness: Harness) => void
  chooseModel: (model: string | null) => void
  chooseEffort: (effort: string | null) => void
} {
  const { defaultHarness } = useHarnesses()
  const [chosenHarness, setChosenHarness] = useState<Harness | null>(null)
  const [model, setModel] = useState<string | null>(null)
  const [effort, setEffort] = useState<string | null>(null)
  return {
    harness: chosenHarness ?? defaultHarness,
    model,
    effort,
    chooseHarness: (harness) => {
      setChosenHarness(harness)
      setModel(null)
      setEffort(null)
    },
    chooseModel: setModel,
    chooseEffort: setEffort,
  }
}

// The harness, the model and the effort of a run, in one row.
export function RunChoice({
  harness,
  model,
  effort,
  onHarness,
  onModel,
  onEffort,
  disabled = false,
}: {
  harness: Harness
  model: string | null
  effort: string | null
  onHarness: (harness: Harness) => void
  onModel: (model: string | null) => void
  onEffort: (effort: string | null) => void
  disabled?: boolean
}) {
  const harnesses = useHarnesses()
  const { state } = useConfig()
  const saved = state.status === 'ready' ? state.config.defaultModels[harness] : undefined
  const savedEffort = state.status === 'ready' ? state.config.defaultEfforts[harness] : undefined
  // Going back to the default shows it again, which the box does not know to do by itself.
  const [again, setAgain] = useState(0)
  const [effortAgain, setEffortAgain] = useState(0)
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
            // An OpenCode variant is part of a model, so it goes when no model applies any more.
            if (harness === 'Opencode' && next === null && saved === undefined && effort !== null) {
              setEffortAgain((n) => n + 1)
              onEffort(null)
            }
          }}
          clearable={model !== null}
          clearLabel="Back to the default"
          disabled={disabled}
          placeholder="The harness chooses"
        />
      </div>
      <div className="run-choice-part">
        <span className="muted small">Effort</span>
        <div className="row">
          <EffortPicker
            // Another harness has other efforts, and a typed variant is shown anew.
            key={`${harness}:${effortAgain}`}
            harness={harness}
            label="Effort for this run"
            // The default of the harness is what is shown until another is chosen.
            value={effort ?? savedEffort ?? null}
            onChange={(next) => {
              if (next === null || next === savedEffort) setEffortAgain((n) => n + 1)
              onEffort(next === savedEffort ? null : next)
            }}
            // An OpenCode variant is part of a model: the one chosen, else the default.
            hasModel={(model ?? saved ?? null) !== null}
            disabled={disabled}
          />
          {effort !== null && (
            <button
              type="button"
              className="link"
              disabled={disabled}
              onClick={() => {
                setEffortAgain((n) => n + 1)
                onEffort(null)
              }}
            >
              Back to the default
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
