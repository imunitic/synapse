// The shell's state: which section is selected, whether the side panel is open
// and which pages are open in tabs. Pure, so it is tested without a browser.

import type { TerminalTask } from '../../shared/transport.ts'
import { titleOf } from '../domain/notes.ts'

export type RailSection = 'definitions' | 'executions' | 'vault' | 'terminals' | 'settings'

export type DefinitionKind = 'pipeline' | 'system' | 'agent' | 'skill'

export const DEFINITION_KINDS: readonly DefinitionKind[] = ['pipeline', 'system', 'agent', 'skill']

export const DEFINITION_LABELS: Record<DefinitionKind, { singular: string; plural: string }> = {
  pipeline: { singular: 'pipeline', plural: 'Pipelines' },
  system: { singular: 'system', plural: 'Systems' },
  agent: { singular: 'agent', plural: 'Agents' },
  skill: { singular: 'skill', plural: 'Skills' },
}

// The categories of the settings, each with a page of its own.
export type SettingsSection =
  'general' | 'vault' | 'graph' | 'environment' | 'integrations' | 'terminals'

export const SETTINGS_SECTIONS: readonly {
  section: SettingsSection
  label: string
  about: string
}[] = [
  {
    section: 'general',
    label: 'General',
    about: 'Work directory, default harness, definition folders',
  },
  { section: 'vault', label: 'Vault', about: 'The vault and how it is kept' },
  { section: 'graph', label: 'Code graph', about: 'Grammars, authoring and staleness checks' },
  { section: 'environment', label: 'Environment', about: 'Variables for what the app runs' },
  {
    section: 'integrations',
    label: 'Integrations',
    about: 'Synapse in Claude Code, Codex and OpenCode',
  },
  { section: 'terminals', label: 'Terminals', about: 'Where a new terminal starts' },
]

export type TerminalKind = 'Shell' | 'Claude' | 'Codex' | 'Opencode'

export type { TerminalTask } from '../../shared/transport.ts'

export const TERMINAL_LABELS: Record<TerminalKind, string> = {
  Shell: 'Shell',
  Claude: 'Claude Code',
  Codex: 'Codex',
  Opencode: 'OpenCode',
}

export const TASK_LABELS: Record<TerminalTask, string> = {
  init: 'build',
  'rebuild-diff': 'rebuild',
  'rebuild-full': 'rebuild all',
}

// One session in a terminal: a login shell, or a harness started directly.
export interface TerminalSession {
  id: string
  kind: TerminalKind
  title: string
  // Where it was started; empty for the home folder.
  cwd: string
  // What it was started to do, when it was started for a task.
  task?: TerminalTask
}

export type Page =
  // The page the app opens on: what needs attention, and where things stand.
  | { kind: 'home' }
  // Searching a code graph's symbols, files and nodes.
  | { kind: 'graph' }
  | { kind: 'settings'; section: SettingsSection }
  | { kind: 'create'; definition: DefinitionKind }
  // A definition's file: a .synapse file, or a skill's SKILL.md.
  | { kind: 'definition'; definition: DefinitionKind; name: string; path: string }
  | { kind: 'execution'; id: string }
  // A note of the vault, by its path.
  | { kind: 'note'; path: string }
  // The terminals: one page with a tab for each session.
  | { kind: 'terminals' }

export interface Tab {
  id: string
  page: Page
}

export interface ShellState {
  section: RailSection
  panelOpen: boolean
  definitionKind: DefinitionKind
  tabs: Tab[]
  activeId: string | null
  // Changes when a definition is made, so that the lists are read again.
  reloadToken: number
  terminals: TerminalSession[]
  activeTerminal: string | null
  // How many sessions were opened, so that no two have the same title.
  terminalsOpened: number
}

export const initialState: ShellState = {
  section: 'definitions',
  panelOpen: true,
  definitionKind: 'pipeline',
  tabs: [],
  activeId: null,
  reloadToken: 0,
  terminals: [],
  activeTerminal: null,
  terminalsOpened: 0,
}

// The state the app starts in: the home page open.
export const startState: ShellState = {
  ...initialState,
  tabs: [{ id: 'home', page: { kind: 'home' } }],
  activeId: 'home',
}

export type Action =
  | { type: 'selectSection'; section: RailSection }
  | { type: 'togglePanel' }
  | { type: 'selectDefinitionKind'; kind: DefinitionKind }
  | { type: 'openPage'; page: Page }
  | { type: 'activateTab'; id: string }
  | { type: 'closeTab'; id: string }
  // A session is added to the terminals page, which shows with it selected.
  | { type: 'openTerminal'; kind: TerminalKind; cwd: string; id: string; task?: TerminalTask }
  | { type: 'selectTerminal'; id: string }
  | { type: 'closeTerminal'; id: string }
  // A definition was changed: the lists are read again.
  | { type: 'definitionsChanged' }
  // A definition was made in the tab closeId: that tab gives way to its page.
  | { type: 'definitionCreated'; closeId: string; page: Page }

export function pageId(page: Page): string {
  switch (page.kind) {
    case 'home':
      return 'home'
    case 'graph':
      return 'graph'
    case 'settings':
      return `settings:${page.section}`
    case 'create':
      return `create:${page.definition}`
    case 'definition':
      return `definition:${page.definition}:${page.name}`
    case 'execution':
      return `execution:${page.id}`
    case 'note':
      return `note:${page.path}`
    case 'terminals':
      return 'terminals'
  }
}

export function pageTitle(page: Page): string {
  switch (page.kind) {
    case 'home':
      return 'Home'
    case 'graph':
      return 'Code graph'
    case 'settings':
      return `${SETTINGS_SECTIONS.find((s) => s.section === page.section)?.label ?? 'Settings'} settings`
    case 'create':
      return `New ${DEFINITION_LABELS[page.definition].singular}`
    case 'definition':
      return page.name
    case 'execution':
      return page.id
    case 'note':
      return titleOf(page.path)
    case 'terminals':
      return 'Terminals'
  }
}

export function reduce(state: ShellState, action: Action): ShellState {
  switch (action.type) {
    case 'selectSection':
      // Choosing the section that is already showing hides the panel.
      if (state.section === action.section && state.panelOpen) return { ...state, panelOpen: false }
      return { ...state, section: action.section, panelOpen: true }

    case 'togglePanel':
      return { ...state, panelOpen: !state.panelOpen }

    case 'selectDefinitionKind':
      return { ...state, definitionKind: action.kind }

    case 'openPage': {
      const id = pageId(action.page)
      const tabs = state.tabs.some((t) => t.id === id)
        ? state.tabs
        : [...state.tabs, { id, page: action.page }]
      return { ...state, tabs, activeId: id }
    }

    case 'activateTab':
      return state.tabs.some((t) => t.id === action.id) ? { ...state, activeId: action.id } : state

    case 'openTerminal': {
      const opened = state.terminalsOpened + 1
      const session: TerminalSession = {
        id: action.id,
        kind: action.kind,
        title: `${TERMINAL_LABELS[action.kind]} ${opened}${
          action.task === undefined ? '' : ` · ${TASK_LABELS[action.task]}`
        }`,
        cwd: action.cwd,
        ...(action.task === undefined ? {} : { task: action.task }),
      }
      return {
        ...reduce(state, { type: 'openPage', page: { kind: 'terminals' } }),
        terminals: [...state.terminals, session],
        activeTerminal: session.id,
        terminalsOpened: opened,
      }
    }

    case 'selectTerminal':
      return state.terminals.some((t) => t.id === action.id)
        ? { ...state, activeTerminal: action.id }
        : state

    case 'closeTerminal': {
      const index = state.terminals.findIndex((t) => t.id === action.id)
      if (index === -1) return state
      const terminals = state.terminals.filter((t) => t.id !== action.id)
      const activeTerminal =
        state.activeTerminal === action.id
          ? (terminals[Math.min(index, terminals.length - 1)]?.id ?? null)
          : state.activeTerminal
      const next = { ...state, terminals, activeTerminal }
      // The page has nothing to show without a session.
      return terminals.length === 0 ? reduce(next, { type: 'closeTab', id: 'terminals' }) : next
    }

    case 'definitionsChanged':
      return { ...state, reloadToken: state.reloadToken + 1 }

    case 'definitionCreated': {
      const opened = reduce(reduce(state, { type: 'closeTab', id: action.closeId }), {
        type: 'openPage',
        page: action.page,
      })
      return { ...opened, reloadToken: state.reloadToken + 1 }
    }

    case 'closeTab': {
      const index = state.tabs.findIndex((t) => t.id === action.id)
      if (index === -1) return state
      const tabs = state.tabs.filter((t) => t.id !== action.id)
      // Closing the active tab moves to the one that took its place, else the last.
      const activeId =
        state.activeId === action.id
          ? (tabs[Math.min(index, tabs.length - 1)]?.id ?? null)
          : state.activeId
      // Closing the terminals page ends every session in it.
      return action.id === 'terminals'
        ? { ...state, tabs, activeId, terminals: [], activeTerminal: null }
        : { ...state, tabs, activeId }
    }
  }
}
