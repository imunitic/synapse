import type { ComponentType, Dispatch } from 'react'
import {
  DefinitionsIcon,
  ExecutionsIcon,
  GraphIcon,
  HomeIcon,
  SettingsIcon,
  SidebarIcon,
  TerminalIcon,
  VaultIcon,
} from '../components/icons.tsx'
import type { Action, RailSection, ShellState } from '../state/state.ts'

const SECTIONS: { section: RailSection; label: string; icon: ComponentType }[] = [
  { section: 'definitions', label: 'Definitions', icon: DefinitionsIcon },
  { section: 'executions', label: 'Executions', icon: ExecutionsIcon },
  { section: 'vault', label: 'Vault', icon: VaultIcon },
  { section: 'settings', label: 'Settings', icon: SettingsIcon },
]

export function Rail({ state, dispatch }: { state: ShellState; dispatch: Dispatch<Action> }) {
  return (
    <nav className="rail" aria-label="Sections">
      <button
        className="rail-button"
        aria-label="Show or hide the side panel"
        title="Show or hide the side panel"
        aria-pressed={state.panelOpen}
        onClick={() => dispatch({ type: 'togglePanel' })}
      >
        <SidebarIcon />
      </button>
      <button
        className="rail-button"
        aria-label="Home"
        title="Home"
        aria-pressed={state.activeId === 'home'}
        onClick={() => dispatch({ type: 'openPage', page: { kind: 'home' } })}
      >
        <HomeIcon />
      </button>
      <button
        className="rail-button"
        aria-label="Code graph"
        title="Code graph"
        aria-pressed={state.activeId === 'graph'}
        onClick={() => dispatch({ type: 'openPage', page: { kind: 'graph' } })}
      >
        <GraphIcon />
      </button>
      <button
        className="rail-button"
        aria-label="Terminals"
        title="Terminals"
        aria-pressed={state.activeId === 'launch' || state.activeId === 'terminals'}
        onClick={() => dispatch({ type: 'openPage', page: { kind: 'launch' } })}
      >
        <TerminalIcon />
      </button>
      <div className="rail-divider" />
      {SECTIONS.map(({ section, label, icon: Glyph }) => (
        <button
          key={section}
          className="rail-button"
          aria-label={label}
          title={label}
          aria-pressed={state.panelOpen && state.section === section}
          onClick={() => {
            // The vault's button also opens its status page, when it shows the section; a second
            // click hides the panel like the others do.
            const showing = state.panelOpen && state.section === section
            dispatch({ type: 'selectSection', section })
            if (section === 'vault' && !showing) {
              dispatch({ type: 'openPage', page: { kind: 'vault' } })
            }
          }}
        >
          <Glyph />
        </button>
      ))}
    </nav>
  )
}
