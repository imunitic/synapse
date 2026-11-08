import type { Dispatch } from 'react'
import { CloseIcon } from '../components/icons.tsx'
import { pageTitle, type Action, type ShellState } from '../state/state.ts'

export function TabBar({ state, dispatch }: { state: ShellState; dispatch: Dispatch<Action> }) {
  return (
    <div className="tabbar" role="tablist" aria-label="Open pages">
      {state.tabs.map((tab) => {
        const selected = tab.id === state.activeId
        return (
          <div key={tab.id} className="tab" data-selected={selected}>
            <button
              role="tab"
              className="tab-label"
              aria-selected={selected}
              onClick={() => dispatch({ type: 'activateTab', id: tab.id })}
            >
              {pageTitle(tab.page)}
            </button>
            <button
              className="icon-button"
              aria-label={`Close ${pageTitle(tab.page)}`}
              onClick={() => dispatch({ type: 'closeTab', id: tab.id })}
            >
              <CloseIcon />
            </button>
          </div>
        )
      })}
    </div>
  )
}
