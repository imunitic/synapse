import { useReducer } from 'react'
import { useConfig } from './config.tsx'
import { PageView } from './pages.tsx'
import { Rail } from './Rail.tsx'
import { SidePanel } from './SidePanel.tsx'
import { StatusBar } from './StatusBar.tsx'
import { initialState, reduce } from './state.ts'
import { TabBar } from './TabBar.tsx'
import './shell.css'

export function Shell() {
  const [state, dispatch] = useReducer(reduce, initialState)
  const { state: config } = useConfig()
  const active = state.tabs.find((tab) => tab.id === state.activeId)
  const missingWorkDir = config.status === 'ready' && config.config.workDir === null

  return (
    <div className="shell">
      <div className="shell-body">
        <Rail state={state} dispatch={dispatch} />
        {state.panelOpen && <SidePanel state={state} dispatch={dispatch} />}
        <main className="main">
          <TabBar state={state} dispatch={dispatch} />
          {missingWorkDir && (
            <div className="banner" role="status">
              <span>
                No work directory is set. Runs without one leave no record and cannot be seen here.
              </span>
              <button
                className="banner-button"
                onClick={() => dispatch({ type: 'openPage', page: { kind: 'settings' } })}
              >
                Set work directory
              </button>
            </div>
          )}
          <div className="content" role="tabpanel">
            {active === undefined ? (
              <p className="empty">Open a page from the side panel.</p>
            ) : (
              <PageView key={active.id} page={active.page} />
            )}
          </div>
        </main>
      </div>
      <StatusBar />
    </div>
  )
}
