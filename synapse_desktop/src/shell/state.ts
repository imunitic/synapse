// The shell's state: which section is selected, whether the side panel is open
// and which pages are open in tabs. Pure, so it is tested without a browser.

export type RailSection = 'definitions' | 'executions' | 'settings'

export type DefinitionKind = 'pipeline' | 'system' | 'agent' | 'skill'

export const DEFINITION_KINDS: readonly DefinitionKind[] = ['pipeline', 'system', 'agent', 'skill']

export const DEFINITION_LABELS: Record<DefinitionKind, { singular: string; plural: string }> = {
  pipeline: { singular: 'pipeline', plural: 'Pipelines' },
  system: { singular: 'system', plural: 'Systems' },
  agent: { singular: 'agent', plural: 'Agents' },
  skill: { singular: 'skill', plural: 'Skills' },
}

export type Page =
  | { kind: 'settings' }
  | { kind: 'create'; definition: DefinitionKind }
  // A definition's file: a .synapse file, or a skill's SKILL.md.
  | { kind: 'definition'; definition: DefinitionKind; name: string; path: string }
  | { kind: 'execution'; id: string }

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
}

export const initialState: ShellState = {
  section: 'definitions',
  panelOpen: true,
  definitionKind: 'pipeline',
  tabs: [],
  activeId: null,
  reloadToken: 0,
}

export type Action =
  | { type: 'selectSection'; section: RailSection }
  | { type: 'togglePanel' }
  | { type: 'selectDefinitionKind'; kind: DefinitionKind }
  | { type: 'openPage'; page: Page }
  | { type: 'activateTab'; id: string }
  | { type: 'closeTab'; id: string }
  // A definition was changed: the lists are read again.
  | { type: 'definitionsChanged' }
  // A definition was made in the tab closeId: that tab gives way to its page.
  | { type: 'definitionCreated'; closeId: string; page: Page }

export function pageId(page: Page): string {
  switch (page.kind) {
    case 'settings':
      return 'settings'
    case 'create':
      return `create:${page.definition}`
    case 'definition':
      return `definition:${page.definition}:${page.name}`
    case 'execution':
      return `execution:${page.id}`
  }
}

export function pageTitle(page: Page): string {
  switch (page.kind) {
    case 'settings':
      return 'Settings'
    case 'create':
      return `New ${DEFINITION_LABELS[page.definition].singular}`
    case 'definition':
      return page.name
    case 'execution':
      return page.id
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
      return { ...state, tabs, activeId }
    }
  }
}
