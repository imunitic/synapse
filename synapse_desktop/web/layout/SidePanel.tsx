import type { Dispatch } from 'react'
import { DefinitionsPanel } from './DefinitionsPanel.tsx'
import { ExecutionsPanel } from './ExecutionsPanel.tsx'
import { useState } from 'react'
import { useConfig } from '../state/config.tsx'
import { useHarnesses } from '../state/diagnosis.tsx'
import { VaultPanel } from './VaultPanel.tsx'
import {
  SETTINGS_SECTIONS,
  TERMINAL_LABELS,
  type Action,
  type ShellState,
  type TerminalKind,
} from '../state/state.ts'

function SettingsPanel({ dispatch }: { dispatch: Dispatch<Action> }) {
  return (
    <>
      <div className="panel-header">
        <h2 className="panel-title">Settings</h2>
      </div>
      <div className="menu">
        {SETTINGS_SECTIONS.map(({ section, label, about }) => (
          <button
            key={section}
            className="menu-item settings-item"
            onClick={() => dispatch({ type: 'openPage', page: { kind: 'settings', section } })}
          >
            <span>{label}</span>
            <span className="muted small">{about}</span>
          </button>
        ))}
      </div>
    </>
  )
}

// An id no other session has.
function newTerminalId(): string {
  return Math.random().toString(36).slice(2, 8)
}

function TerminalsPanel({ dispatch }: { dispatch: Dispatch<Action> }) {
  const { state: config } = useConfig()
  const harnesses = useHarnesses()
  // Where the next session starts: what was typed here, else the default of the
  // settings; empty is the home folder.
  const [typed, setTyped] = useState<string | null>(null)
  const folder = typed ?? (config.status === 'ready' ? (config.config.terminalFolder ?? '') : '')

  function start(kind: TerminalKind) {
    dispatch({ type: 'openTerminal', kind, cwd: folder.trim(), id: newTerminalId() })
  }

  return (
    <>
      <div className="panel-header">
        <h2 className="panel-title">Terminals</h2>
      </div>
      <div className="menu">
        <label className="field panel-field">
          <span className="muted small">Start in</span>
          <input
            className="mono"
            value={folder}
            placeholder="your home folder"
            onChange={(event) => setTyped(event.target.value)}
          />
        </label>
        {(['Shell', 'Claude', 'Codex', 'Opencode'] as const).map((kind) => {
          // A harness that is not installed is there, and says why it cannot be started.
          const reason = kind === 'Shell' ? null : harnesses.reason(kind)
          return (
            <button
              key={kind}
              className="menu-item"
              disabled={reason !== null}
              title={reason ?? undefined}
              onClick={() => start(kind)}
            >
              {kind === 'Shell' ? 'New shell' : TERMINAL_LABELS[kind]}
              {reason !== null && <span className="muted small"> · not found</span>}
            </button>
          )
        })}
      </div>
    </>
  )
}

export function SidePanel({ state, dispatch }: { state: ShellState; dispatch: Dispatch<Action> }) {
  return (
    <aside className="panel" aria-label="Side panel">
      {state.section === 'definitions' && <DefinitionsPanel state={state} dispatch={dispatch} />}
      {state.section === 'executions' && <ExecutionsPanel state={state} dispatch={dispatch} />}
      {state.section === 'vault' && <VaultPanel state={state} dispatch={dispatch} />}
      {state.section === 'terminals' && <TerminalsPanel dispatch={dispatch} />}
      {state.section === 'settings' && <SettingsPanel dispatch={dispatch} />}
    </aside>
  )
}
