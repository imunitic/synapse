// The shell's state: which section is selected, whether the side panel is open
// and which pages are open in tabs. Pure, so it is tested without a browser.

import type { ChangesBase } from '../domain/changes.ts'
import type { ActionKind } from '../domain/activity.ts'
import type { TerminalInfo, TerminalTask } from '../../shared/transport.ts'
import { titleOf } from '../domain/notes.ts'
import { clampIndex } from '../domain/tabs.ts'

export type RailSection = 'definitions' | 'executions' | 'vault' | 'settings'

export type DefinitionKind = 'pipeline' | 'system' | 'agent' | 'skill'

// The record without the entry of `key`.
function without<T>(record: Record<string, T>, key: string): Record<string, T> {
  return Object.fromEntries(Object.entries(record).filter(([name]) => name !== key))
}

// The tabs of the Changes sidebar for a terminal session: its changes, the commits of its branch,
// and what its harness did.
export type ChangesTab = 'changes' | 'git' | 'activity'

export const DEFINITION_KINDS: readonly DefinitionKind[] = ['pipeline', 'system', 'agent', 'skill']

export const DEFINITION_LABELS: Record<DefinitionKind, { singular: string; plural: string }> = {
  pipeline: { singular: 'pipeline', plural: 'Pipelines' },
  system: { singular: 'system', plural: 'Systems' },
  agent: { singular: 'agent', plural: 'Agents' },
  skill: { singular: 'skill', plural: 'Skills' },
}

// The categories of the settings, each with a page of its own.
export type SettingsSection =
  'general' | 'vault' | 'conventions' | 'graph' | 'environment' | 'integrations' | 'terminals'

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
  {
    section: 'conventions',
    label: 'Conventions',
    about: 'Projects, tags, stopwords and the code graph\u2019s rules',
  },
  { section: 'graph', label: 'Code graph', about: 'Grammars, authoring and staleness checks' },
  { section: 'environment', label: 'Environment', about: 'Variables for what the app runs' },
  {
    section: 'integrations',
    label: 'Integrations',
    about: 'Synapse in Claude Code, Codex and OpenCode',
  },
  { section: 'terminals', label: 'Terminals', about: 'Where a new shell starts' },
]

// A session in the terminals: a shell, a harness, or an interactive run of a pipeline.
export type TerminalKind = 'Shell' | 'Pipeline' | 'Claude' | 'Codex' | 'Opencode'

export type { TerminalTask } from '../../shared/transport.ts'

export const TERMINAL_LABELS: Record<TerminalKind, string> = {
  Shell: 'Shell',
  Pipeline: 'Run',
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
  // A line to run in it as soon as it starts, when it was opened to run one.
  command?: string
  // The id of a session of the harness that it continues.
  resume?: string
  // The pipeline an interactive run is of, and the input it was started with.
  pipeline?: string
  input?: unknown
  // The id of the run it started, once the server has said.
  executionId?: string
  // Set when its program has ended, which leaves the tab for the person to read and close.
  ended?: boolean
  // The host holds the session already: it is attached to, and none is started.
  attach?: boolean
  // The name the person gave it, shown instead of its title.
  name?: string
}

// What a session's tab and lists show: the name it was given, else its title.
export function terminalName(session: TerminalSession): string {
  return session.name ?? session.title
}

// An interactive run whose program is still going.
export function isLiveRun(session: TerminalSession): boolean {
  return session.kind === 'Pipeline' && session.ended !== true
}

export type Page =
  // The page the app opens on: what needs attention, and where things stand.
  | { kind: 'home' }
  // Searching a code graph's symbols, files and nodes.
  | { kind: 'graph' }
  | { kind: 'settings'; section: SettingsSection }
  | { kind: 'create'; definition: DefinitionKind }
  // Describing a note for an agent to write into the vault.
  | { kind: 'new-note' }
  // A definition's file: a .synapse file, or a skill's SKILL.md.
  | { kind: 'definition'; definition: DefinitionKind; name: string; path: string }
  | { kind: 'execution'; id: string }
  // A note of the vault, by its path.
  | { kind: 'note'; path: string }
  // What the vault says needs a decision.
  | { kind: 'vault' }
  // The terminals: one page with a tab for each session.
  | { kind: 'terminals' }
  // Where a shell, or a harness in a folder it works in, is started.
  | { kind: 'launch' }

export interface Tab {
  id: string
  page: Page
}

export interface ShellState {
  section: RailSection
  panelOpen: boolean
  // The Changes sidebar on the right, which is shut until it is opened.
  changesOpen: boolean
  // The visit of a run that the Changes sidebar was asked to show, until another is.
  changesVisit: number | null
  // The file, by the whole path an activity names it with, that the sidebar was asked to show.
  changesFile: string | null
  // What each terminal session's changes are against, where the person has chosen.
  changesBases: Record<string, ChangesBase>
  // The sidebar tab each terminal session shows, where the person has chosen one.
  changesTabs: Record<string, ChangesTab>
  // The commit each session's Git tab shows, by its hash; none is the list of commits.
  gitCommits: Record<string, string | null>
  // The kinds of action each session's Activity tab shows; none is all.
  activityKinds: Record<string, ActionKind[]>
  // The file each session's Activity tab shows the actions on; none is every file.
  activityFiles: Record<string, string | null>
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
  changesOpen: false,
  changesVisit: null,
  changesFile: null,
  changesBases: {},
  changesTabs: {},
  gitCommits: {},
  activityKinds: {},
  activityFiles: {},
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
  // The panel is put open or shut, as the width of the window asks.
  | { type: 'setPanel'; open: boolean }
  | { type: 'toggleChanges' }
  | { type: 'setChangesBase'; session: string; base: ChangesBase }
  | { type: 'setChangesTab'; session: string; tab: ChangesTab }
  // A commit of the session's Git tab is shown, or, with none, its list.
  | { type: 'setGitCommit'; session: string; commit: string | null }
  | { type: 'setActivityKinds'; session: string; kinds: ActionKind[] }
  | { type: 'setActivityFile'; session: string; file: string | null }
  | { type: 'showChanges'; visit: number | null; path?: string }
  | { type: 'selectDefinitionKind'; kind: DefinitionKind }
  | { type: 'openPage'; page: Page }
  | { type: 'activateTab'; id: string }
  | { type: 'closeTab'; id: string }
  // A session is added to the terminals page, which shows with it selected.
  | {
      type: 'openTerminal'
      kind: TerminalKind
      cwd: string
      id: string
      task?: TerminalTask
      // A line to run in it, and the name its tab has instead of `Shell 2`.
      command?: string
      title?: string
      // A session of the harness that it continues.
      resume?: string
      // An interactive run of this pipeline, given this input.
      pipeline?: string
      input?: unknown
    }
  // Sessions the host held when the page began, which are attached to.
  | { type: 'adoptTerminals'; sessions: TerminalInfo[] }
  | { type: 'selectTerminal'; id: string }
  // The run a pipeline terminal started has this id.
  | { type: 'terminalRun'; id: string; executionId: string }
  // The program of a session ended.
  | { type: 'terminalEnded'; id: string }
  // The host holds the session now: a view that is made again for it attaches, and starts none.
  | { type: 'terminalClaimed'; id: string }
  // The person named a session; a blank name gives it back its title.
  | { type: 'renameTerminal'; id: string; name: string }
  // A tab is put at `to`, its index in the list of tabs once it is taken out. The Home tab stays
  // first, and nothing goes before it.
  | { type: 'moveTab'; id: string; to: number }
  // A shell tab is put at `to`, its index in the list of terminals once it is taken out.
  | { type: 'moveTerminal'; id: string; to: number }
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
    case 'new-note':
      return 'new-note'
    case 'vault':
      return 'vault'
    case 'definition':
      return `definition:${page.definition}:${page.name}`
    case 'execution':
      return `execution:${page.id}`
    case 'note':
      return `note:${page.path}`
    case 'terminals':
      return 'terminals'
    case 'launch':
      return 'launch'
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
    case 'new-note':
      return 'New note'
    case 'vault':
      return 'Vault'
    case 'definition':
      return page.name
    case 'execution':
      return page.id
    case 'note':
      return titleOf(page.path)
    case 'terminals':
      return 'Terminals'
    case 'launch':
      return 'New terminal'
  }
}

// The section of the rail a page belongs to, when it belongs to one: the notes are in the vault,
// the runs are executions, a definition is a definition of its kind. The pages of the rail's own
// buttons, above its divider, belong to no section.
export function sectionOf(page: Page): { section: RailSection; kind?: DefinitionKind } | null {
  switch (page.kind) {
    case 'note':
    case 'new-note':
    case 'vault':
      return { section: 'vault' }
    case 'execution':
      return { section: 'executions' }
    case 'definition':
    case 'create':
      return { section: 'definitions', kind: page.definition }
    case 'settings':
      return { section: 'settings' }
    default:
      return null
  }
}

// The side panel follows the page that is showing: when another page comes to show, by being
// opened, chosen or taken over from a closed one, the panel is on the section of that page. Whether
// the panel is open is the person's.
export function reduce(state: ShellState, action: Action): ShellState {
  const next = step(state, action)
  if (next.activeId === state.activeId) return next
  const page = next.tabs.find((t) => t.id === next.activeId)?.page
  const where = page === undefined ? null : sectionOf(page)
  if (where === null) return next
  const kind = where.kind ?? next.definitionKind
  return where.section === next.section && kind === next.definitionKind
    ? next
    : { ...next, section: where.section, definitionKind: kind }
}

function step(state: ShellState, action: Action): ShellState {
  switch (action.type) {
    case 'selectSection':
      // Choosing the section that is already showing hides the panel.
      if (state.section === action.section && state.panelOpen) return { ...state, panelOpen: false }
      return { ...state, section: action.section, panelOpen: true }

    case 'togglePanel':
      return { ...state, panelOpen: !state.panelOpen }

    case 'toggleChanges':
      return { ...state, changesOpen: !state.changesOpen }

    case 'setChangesBase':
      return { ...state, changesBases: { ...state.changesBases, [action.session]: action.base } }

    case 'setChangesTab':
      return { ...state, changesTabs: { ...state.changesTabs, [action.session]: action.tab } }

    case 'setGitCommit':
      return { ...state, gitCommits: { ...state.gitCommits, [action.session]: action.commit } }

    case 'setActivityKinds':
      return {
        ...state,
        activityKinds: { ...state.activityKinds, [action.session]: action.kinds },
      }

    case 'setActivityFile':
      return {
        ...state,
        activityFiles: { ...state.activityFiles, [action.session]: action.file },
      }

    case 'showChanges':
      return {
        ...state,
        changesOpen: true,
        changesVisit: action.visit,
        changesFile: action.path ?? null,
      }

    case 'setPanel':
      return state.panelOpen === action.open ? state : { ...state, panelOpen: action.open }

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
        title:
          action.title ??
          `${TERMINAL_LABELS[action.kind]} ${opened}${
            action.task === undefined ? '' : ` · ${TASK_LABELS[action.task]}`
          }`,
        cwd: action.cwd,
        ...(action.task === undefined ? {} : { task: action.task }),
        ...(action.command === undefined ? {} : { command: action.command }),
        ...(action.resume === undefined ? {} : { resume: action.resume }),
        ...(action.pipeline === undefined ? {} : { pipeline: action.pipeline }),
        ...(action.input === undefined ? {} : { input: action.input }),
      }
      return {
        ...reduce(state, { type: 'openPage', page: { kind: 'terminals' } }),
        terminals: [...state.terminals, session],
        activeTerminal: session.id,
        terminalsOpened: opened,
      }
    }

    case 'adoptTerminals': {
      const fresh = action.sessions.filter((s) => !state.terminals.some((t) => t.id === s.session))
      if (fresh.length === 0) return state
      const adopted: TerminalSession[] = fresh.map((s) => ({
        id: s.session,
        kind: s.kind,
        title: s.title,
        cwd: s.cwd,
        ...(s.task === undefined ? {} : { task: s.task }),
        ...(s.pipeline === undefined ? {} : { pipeline: s.pipeline }),
        ...(s.executionId === undefined ? {} : { executionId: s.executionId }),
        ...(s.exited === null ? {} : { ended: true }),
        attach: true,
      }))
      // Their page is among the tabs, and the one that shows stays what it is.
      const id = pageId({ kind: 'terminals' })
      return {
        ...state,
        tabs: state.tabs.some((t) => t.id === id)
          ? state.tabs
          : [...state.tabs, { id, page: { kind: 'terminals' } }],
        terminals: [...state.terminals, ...adopted],
        activeTerminal: state.activeTerminal ?? adopted[0]?.id ?? null,
        terminalsOpened: state.terminalsOpened + adopted.length,
      }
    }

    case 'terminalRun':
      return state.terminals.some((t) => t.id === action.id && t.executionId === undefined)
        ? {
            ...state,
            terminals: state.terminals.map((t) =>
              t.id === action.id ? { ...t, executionId: action.executionId } : t,
            ),
          }
        : state

    case 'renameTerminal': {
      const session = state.terminals.find((t) => t.id === action.id)
      if (session === undefined) return state
      const name = action.name.trim()
      if ((session.name ?? '') === name) return state
      return {
        ...state,
        terminals: state.terminals.map((t) => {
          if (t.id !== action.id) return t
          if (name !== '') return { ...t, name }
          const unnamed = { ...t }
          delete unnamed.name
          return unnamed
        }),
      }
    }

    case 'terminalClaimed':
      return state.terminals.some((t) => t.id === action.id && t.attach !== true)
        ? {
            ...state,
            terminals: state.terminals.map((t) =>
              t.id === action.id ? { ...t, attach: true } : t,
            ),
          }
        : state

    case 'terminalEnded':
      return state.terminals.some((t) => t.id === action.id && t.ended !== true)
        ? {
            ...state,
            terminals: state.terminals.map((t) => (t.id === action.id ? { ...t, ended: true } : t)),
          }
        : state

    case 'moveTab': {
      const from = state.tabs.findIndex((t) => t.id === action.id)
      const moved = state.tabs[from]
      if (moved === undefined || action.id === 'home') return state
      const ids = state.tabs.map((t) => t.id)
      const to = clampIndex(action.to, ids)
      if (to === from) return state
      const tabs = state.tabs.filter((t) => t.id !== action.id)
      tabs.splice(to, 0, moved)
      return { ...state, tabs }
    }

    case 'moveTerminal': {
      const from = state.terminals.findIndex((t) => t.id === action.id)
      if (from === -1) return state
      const to = Math.min(Math.max(action.to, 0), state.terminals.length - 1)
      if (to === from) return state
      const terminals = state.terminals.filter((t) => t.id !== action.id)
      terminals.splice(to, 0, state.terminals[from]!)
      return { ...state, terminals }
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
      // What its sidebar showed goes with it.
      const next = {
        ...state,
        terminals,
        activeTerminal,
        changesTabs: without(state.changesTabs, action.id),
        gitCommits: without(state.gitCommits, action.id),
        activityKinds: without(state.activityKinds, action.id),
        activityFiles: without(state.activityFiles, action.id),
      }
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
      // The Home tab is always there: there is a page to come back to, whatever else is closed.
      if (action.id === 'home') return state
      const index = state.tabs.findIndex((t) => t.id === action.id)
      if (index === -1) return state
      const tabs = state.tabs.filter((t) => t.id !== action.id)
      // Closing the active tab moves to the one that took its place, else the last.
      const activeId =
        state.activeId === action.id
          ? (tabs[Math.min(index, tabs.length - 1)]?.id ?? null)
          : state.activeId
      // Closing the terminals page ends the sessions in it, except an interactive run that is going
      // on: closing the tab is not stopping the run, which stays where it can be shown again.
      if (action.id !== 'terminals') return { ...state, tabs, activeId }
      const terminals = state.terminals.filter(isLiveRun)
      return {
        ...state,
        tabs,
        activeId,
        terminals,
        activeTerminal: terminals.some((t) => t.id === state.activeTerminal)
          ? state.activeTerminal
          : (terminals[0]?.id ?? null),
      }
    }
  }
}
