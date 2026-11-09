import type { Dispatch } from 'react'
import { DefinitionsPanel } from './DefinitionsPanel.tsx'
import { ExecutionsPanel } from './ExecutionsPanel.tsx'
import { VaultPanel } from './VaultPanel.tsx'
import { SETTINGS_SECTIONS, type Action, type ShellState } from '../state/state.ts'

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

export function SidePanel({ state, dispatch }: { state: ShellState; dispatch: Dispatch<Action> }) {
  return (
    <aside className="panel" aria-label="Side panel">
      {state.section === 'definitions' && <DefinitionsPanel state={state} dispatch={dispatch} />}
      {state.section === 'executions' && <ExecutionsPanel state={state} dispatch={dispatch} />}
      {state.section === 'vault' && <VaultPanel state={state} dispatch={dispatch} />}
      {state.section === 'settings' && <SettingsPanel dispatch={dispatch} />}
    </aside>
  )
}
