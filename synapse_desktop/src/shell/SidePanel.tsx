import type { Dispatch } from 'react'
import { DefinitionsPanel } from './DefinitionsPanel.tsx'
import { ExecutionsPanel } from './ExecutionsPanel.tsx'
import type { Action, ShellState } from './state.ts'

function SettingsPanel({ dispatch }: { dispatch: Dispatch<Action> }) {
  return (
    <>
      <div className="panel-header">
        <h2 className="panel-title">Settings</h2>
      </div>
      <div className="menu">
        <button
          className="menu-item"
          onClick={() => dispatch({ type: 'openPage', page: { kind: 'settings' } })}
        >
          Work directory
        </button>
      </div>
    </>
  )
}

export function SidePanel({ state, dispatch }: { state: ShellState; dispatch: Dispatch<Action> }) {
  return (
    <aside className="panel" aria-label="Side panel">
      {state.section === 'definitions' && <DefinitionsPanel state={state} dispatch={dispatch} />}
      {state.section === 'executions' && <ExecutionsPanel state={state} dispatch={dispatch} />}
      {state.section === 'settings' && <SettingsPanel dispatch={dispatch} />}
    </aside>
  )
}
