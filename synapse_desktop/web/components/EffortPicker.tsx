import { useState } from 'react'
import { effortsOf, VARIANT_NAME } from '../../shared/efforts.ts'
import type { Harness } from '../../shared/transport.ts'

const NONE = 'The harness chooses'

const BAD_VARIANT =
  'A variant has letters, digits and the characters . _ - and starts with a letter or a digit.'

// A choice of how much effort the model of a harness is asked to put in. Claude and Codex offer a
// list. For OpenCode it is a variant of the model, typed by name, and given only as part of a
// model, so it waits until a model applies. Choosing none leaves the effort to the harness.
export function EffortPicker({
  harness,
  label,
  value,
  onChange,
  hasModel,
  disabled = false,
}: {
  harness: Harness
  label: string
  // The effort shown: the one chosen, else the default; null shows "The harness chooses".
  value: string | null
  onChange: (effort: string | null) => void
  // OpenCode only: whether a model applies, without which a variant cannot be given.
  hasModel: boolean
  disabled?: boolean
}) {
  const efforts = effortsOf(harness)
  if (efforts !== null) {
    return (
      <select
        aria-label={label}
        value={value ?? ''}
        disabled={disabled}
        onChange={(event) => onChange(event.target.value === '' ? null : event.target.value)}
      >
        <option value="">{NONE}</option>
        {efforts.map((effort) => (
          <option key={effort} value={effort}>
            {effort}
          </option>
        ))}
      </select>
    )
  }
  return (
    <VariantField
      label={label}
      value={value}
      onChange={onChange}
      disabled={disabled || !hasModel}
      waiting={!hasModel}
    />
  )
}

// OpenCode's variant, typed by name and given when the box is left or Enter is pressed. A new value
// from the caller is shown when the field is made anew, which the caller does by its key.
function VariantField({
  label,
  value,
  onChange,
  disabled,
  waiting,
}: {
  label: string
  value: string | null
  onChange: (effort: string | null) => void
  disabled: boolean
  waiting: boolean
}) {
  const [draft, setDraft] = useState(value ?? '')
  const [problem, setProblem] = useState<string | null>(null)

  function commit(text: string) {
    const name = text.trim()
    if (name === '') {
      setProblem(null)
      if (value !== null) onChange(null)
      return
    }
    if (!VARIANT_NAME.test(name)) {
      setProblem(BAD_VARIANT)
      return
    }
    setProblem(null)
    setDraft(name)
    if (name !== value) onChange(name)
  }

  return (
    <div className="effort-picker">
      <label className="row">
        <span className="muted small">Variant</span>
        <input
          className="mono"
          aria-label={label}
          value={draft}
          disabled={disabled}
          placeholder={NONE}
          onChange={(event) => {
            setDraft(event.target.value)
            setProblem(null)
          }}
          onBlur={() => commit(draft)}
          onKeyDown={(event) => {
            if (event.key === 'Enter') {
              event.preventDefault()
              commit(draft)
            } else if (event.key === 'Escape') {
              setDraft(value ?? '')
              setProblem(null)
            }
          }}
        />
      </label>
      {waiting && <p className="muted small">Choose a model first</p>}
      {problem !== null && (
        <p className="error small" role="alert">
          {problem}
        </p>
      )}
    </div>
  )
}
