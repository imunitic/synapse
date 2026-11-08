import { useReducer } from 'react'
import { useConfig } from './config.tsx'
import { PageView } from './pages.tsx'
import { Rail } from './Rail.tsx'
import { SidePanel } from './SidePanel.tsx'
import { StatusBar } from './StatusBar.tsx'
import { TerminalsPage } from './TerminalsPage.tsx'
import { reduce, startState } from './state.ts'
import { TabBar } from './TabBar.tsx'
import './shell.css'

export function Shell() {
  const [state, dispatch] = useReducer(reduce, startState)
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
                There is no home directory to keep Synapse's working files in, so runs leave no
                record. Set a work directory.
              </span>
              <button
                className="banner-button"
                onClick={() =>
                  dispatch({ type: 'openPage', page: { kind: 'settings', section: 'general' } })
                }
              >
                Set work directory
              </button>
            </div>
          )}
          <div className="content" role="tabpanel">
            {active === undefined && <p className="empty">Open a page from the side panel.</p>}
            {/* A session goes on while another tab shows, so the terminals stay mounted. */}
            {state.terminals.length > 0 && (
              <TerminalsPage
                sessions={state.terminals}
                activeId={state.activeTerminal}
                visible={active?.page.kind === 'terminals'}
                onSelect={(id) => dispatch({ type: 'selectTerminal', id })}
                onClose={(id) => dispatch({ type: 'closeTerminal', id })}
                onNew={() =>
                  dispatch({
                    type: 'openTerminal',
                    kind: 'Shell',
                    cwd: '',
                    id: Math.random().toString(36).slice(2, 8),
                  })
                }
              />
            )}
            {active !== undefined && active.page.kind !== 'terminals' && (
              <PageView
                key={active.id}
                page={active.page}
                onOpen={(page) => dispatch({ type: 'openPage', page })}
                terminals={state.terminals}
                onSelectTerminal={(id) => {
                  dispatch({ type: 'openPage', page: { kind: 'terminals' } })
                  dispatch({ type: 'selectTerminal', id })
                }}
                onStartTask={(kind, cwd, task) =>
                  dispatch({
                    type: 'openTerminal',
                    kind,
                    cwd,
                    task,
                    id: Math.random().toString(36).slice(2, 8),
                  })
                }
                onStartTerminal={(kind) =>
                  dispatch({
                    type: 'openTerminal',
                    kind,
                    cwd: config.status === 'ready' ? (config.config.terminalFolder ?? '') : '',
                    id: Math.random().toString(36).slice(2, 8),
                  })
                }
                onRunCommand={(command, title) =>
                  dispatch({
                    type: 'openTerminal',
                    kind: 'Shell',
                    cwd: config.status === 'ready' ? (config.config.terminalFolder ?? '') : '',
                    command,
                    title,
                    id: Math.random().toString(36).slice(2, 8),
                  })
                }
                onCreated={(page) =>
                  dispatch({ type: 'definitionCreated', closeId: active.id, page })
                }
                onChanged={() => dispatch({ type: 'definitionsChanged' })}
                onCancel={() => dispatch({ type: 'closeTab', id: active.id })}
              />
            )}
          </div>
        </main>
      </div>
      <StatusBar />
    </div>
  )
}
