import { useState } from 'react'
import { useHarnesses } from '../../state/diagnosis.tsx'
import { TERMINAL_LABELS, type TerminalKind } from '../../state/state.ts'

// The harness a graph is built with: the one chosen here, else the default.
export function useHarness(): { harness: TerminalKind; choose: (kind: TerminalKind) => void } {
  const { defaultHarness } = useHarnesses()
  const [chosen, setChosen] = useState<TerminalKind | null>(null)
  return { harness: chosen ?? defaultHarness, choose: setChosen }
}

export function HarnessSelect({
  label,
  harness,
  onChange,
}: {
  label: string
  harness: TerminalKind
  onChange: (kind: TerminalKind) => void
}) {
  const harnesses = useHarnesses()
  return (
    <label className="field">
      <span className="muted small">Harness</span>
      <select
        aria-label={label}
        value={harness}
        onChange={(event) => onChange(event.target.value as TerminalKind)}
      >
        {(['Claude', 'Codex', 'Opencode'] as const).map((kind) => (
          <option key={kind} value={kind} disabled={harnesses.isMissing(kind)}>
            {TERMINAL_LABELS[kind]}
            {harnesses.isMissing(kind) ? ' (not installed)' : ''}
          </option>
        ))}
      </select>
    </label>
  )
}
