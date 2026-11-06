import type { Dispatch } from 'react'
import { PlusIcon } from './icons.tsx'
import { DEFINITION_KINDS, DEFINITION_LABELS, type Action, type ShellState } from './state.ts'

function DefinitionsPanel({ state, dispatch }: { state: ShellState; dispatch: Dispatch<Action> }) {
  const labels = DEFINITION_LABELS[state.definitionKind]
  return (
    <>
      <div className="panel-header">
        <h2 className="panel-title">Definitions</h2>
        <button
          className="icon-button"
          aria-label={`New ${labels.singular}`}
          onClick={() =>
            dispatch({
              type: 'openPage',
              page: { kind: 'create', definition: state.definitionKind },
            })
          }
        >
          <PlusIcon />
        </button>
      </div>
      <div className="subtabs" role="group" aria-label="Kind of definition">
        {DEFINITION_KINDS.map((kind) => (
          <button
            key={kind}
            className="subtab"
            aria-pressed={state.definitionKind === kind}
            onClick={() => dispatch({ type: 'selectDefinitionKind', kind })}
          >
            {DEFINITION_LABELS[kind].plural}
          </button>
        ))}
      </div>
      <p className="panel-empty">No {labels.plural.toLowerCase()} listed yet.</p>
    </>
  )
}

function ExecutionsPanel() {
  return (
    <>
      <div className="panel-header">
        <h2 className="panel-title">Executions</h2>
      </div>
      <p className="panel-empty">No executions listed yet.</p>
    </>
  )
}

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
      {state.section === 'executions' && <ExecutionsPanel />}
      {state.section === 'settings' && <SettingsPanel dispatch={dispatch} />}
    </aside>
  )
}
