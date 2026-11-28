import { useEffect, useState, type Dispatch } from 'react'
import { DefinitionsPanel } from './DefinitionsPanel.tsx'
import { ExecutionsPanel } from './ExecutionsPanel.tsx'
import { ResizeHandle } from './ResizeHandle.tsx'
import { useResizableWidth } from './use-resizable-width.ts'
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

// The window's width, read again when the window is resized.
function useWindowWidth(): number {
  const [width, setWidth] = useState(() => window.innerWidth)
  useEffect(() => {
    const onResize = () => setWidth(window.innerWidth)
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [])
  return width
}

// The root font size in pixels, which the Text size setting changes.
function remPx(): number {
  return parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
}

export function SidePanel({ state, dispatch }: { state: ShellState; dispatch: Dispatch<Action> }) {
  const windowWidth = useWindowWidth()
  const rem = remPx()
  // One width for every section: it starts at 18rem, goes no narrower than 16.5rem and no wider
  // than half the window.
  const { width, handleProps } = useResizableWidth({
    key: 'synapse-desktop.panel-width',
    min: 16.5 * rem,
    max: Math.max(16.5 * rem, windowWidth / 2),
    initial: 18 * rem,
    edge: 'left',
  })
  return (
    <aside className="panel" aria-label="Side panel" style={{ width }}>
      <div className="panel-body">
        {state.section === 'definitions' && <DefinitionsPanel state={state} dispatch={dispatch} />}
        {state.section === 'executions' && <ExecutionsPanel state={state} dispatch={dispatch} />}
        {state.section === 'vault' && <VaultPanel state={state} dispatch={dispatch} />}
        {state.section === 'settings' && <SettingsPanel dispatch={dispatch} />}
      </div>
      <ResizeHandle
        className="panel-resize"
        label="Resize the side panel"
        handleProps={handleProps}
      />
    </aside>
  )
}
