import type { Dispatch } from 'react'
import { DefinitionsPanel } from './DefinitionsPanel.tsx'
import { ExecutionsPanel } from './ExecutionsPanel.tsx'
import { useState } from 'react'
import { TERMINAL_LABELS, type Action, type ShellState, type TerminalKind } from './state.ts'

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
          All settings
        </button>
      </div>
    </>
  )
}

// An id no other session has.
function newTerminalId(): string {
  return Math.random().toString(36).slice(2, 8)
}

const FOLDER_KEY = 'synapse-desktop.terminal-folder'

function TerminalsPanel({ dispatch }: { dispatch: Dispatch<Action> }) {
  // Where the next session starts; empty is the home folder.
  const [folder, setFolder] = useState(() => {
    try {
      return localStorage.getItem(FOLDER_KEY) ?? ''
    } catch {
      return ''
    }
  })

  function start(kind: TerminalKind) {
    try {
      localStorage.setItem(FOLDER_KEY, folder)
    } catch {
      // Nothing is remembered; the folder still applies to this session.
    }
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
            onChange={(event) => setFolder(event.target.value)}
          />
        </label>
        {(['Shell', 'Claude', 'Codex', 'Opencode'] as const).map((kind) => (
          <button key={kind} className="menu-item" onClick={() => start(kind)}>
            {kind === 'Shell' ? 'New shell' : TERMINAL_LABELS[kind]}
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
      {state.section === 'terminals' && <TerminalsPanel dispatch={dispatch} />}
      {state.section === 'settings' && <SettingsPanel dispatch={dispatch} />}
    </aside>
  )
}
