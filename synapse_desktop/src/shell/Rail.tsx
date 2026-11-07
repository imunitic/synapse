import type { ComponentType, Dispatch } from 'react'
import {
  DefinitionsIcon,
  ExecutionsIcon,
  SettingsIcon,
  SidebarIcon,
  TerminalIcon,
} from './icons.tsx'
import type { Action, RailSection, ShellState } from './state.ts'

const SECTIONS: { section: RailSection; label: string; icon: ComponentType }[] = [
  { section: 'definitions', label: 'Definitions', icon: DefinitionsIcon },
  { section: 'executions', label: 'Executions', icon: ExecutionsIcon },
  { section: 'terminals', label: 'Terminals', icon: TerminalIcon },
  { section: 'settings', label: 'Settings', icon: SettingsIcon },
]

export function Rail({ state, dispatch }: { state: ShellState; dispatch: Dispatch<Action> }) {
  return (
    <nav className="rail" aria-label="Sections">
      <button
        className="rail-button"
        aria-label="Show or hide the side panel"
        aria-pressed={state.panelOpen}
        onClick={() => dispatch({ type: 'togglePanel' })}
      >
        <SidebarIcon />
      </button>
      <div className="rail-divider" />
      {SECTIONS.map(({ section, label, icon: Glyph }) => (
        <button
          key={section}
          className="rail-button"
          aria-label={label}
          aria-pressed={state.panelOpen && state.section === section}
          onClick={() => dispatch({ type: 'selectSection', section })}
        >
          <Glyph />
        </button>
      ))}
    </nav>
  )
}
