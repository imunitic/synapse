import { describe, expect, it } from 'vitest'
import {
  initialState,
  pageId,
  pageTitle,
  reduce,
  sectionOf,
  SETTINGS_SECTIONS,
  startState,
  tabTitle,
  terminalName,
  type Action,
  type ShellState,
} from './state.ts'

function run(actions: Action[], from: ShellState = initialState): ShellState {
  return actions.reduce(reduce, from)
}

const settings = { kind: 'settings', section: 'general' } as const
const newPipeline = { kind: 'create', definition: 'pipeline' } as const
const newAgent = { kind: 'create', definition: 'agent' } as const

describe('note pages', () => {
  it('are a page for each note, named by its file, opened once', () => {
    const note = { kind: 'note', path: 'designs/p/Talk.md' } as const
    expect(pageId(note)).toBe('note:designs/p/Talk.md')
    expect(pageTitle(note)).toBe('Talk')
    const twice = [note, note, { kind: 'note', path: 'tasks/p/Work.md' } as const].reduce(
      (state, page) => reduce(state, { type: 'openPage', page }),
      initialState,
    )
    expect(twice.tabs.map((t) => t.id)).toEqual(['note:designs/p/Talk.md', 'note:tasks/p/Work.md'])
    expect(twice.activeId).toBe('note:tasks/p/Work.md')
  })

  it('have a section in the rail that shows its panel', () => {
    const state = reduce(initialState, { type: 'selectSection', section: 'vault' })
    expect(state).toMatchObject({ section: 'vault', panelOpen: true })
  })
})

describe('the new note page', () => {
  it('is one tab, with its own id and title, that opening again does not repeat', () => {
    const page = { kind: 'new-note' } as const
    expect(pageId(page)).toBe('new-note')
    expect(pageTitle(page)).toBe('New note')
    const twice = reduce(reduce(initialState, { type: 'openPage', page }), {
      type: 'openPage',
      page,
    })
    expect(twice.tabs).toHaveLength(1)
  })

  it('is replaced by the note that was written, and the lists are read again', () => {
    const opened = reduce(initialState, { type: 'openPage', page: { kind: 'new-note' } })
    const done = reduce(opened, {
      type: 'definitionCreated',
      closeId: 'new-note',
      page: { kind: 'note', path: 'research/A.md' },
    })
    expect(done.tabs.map((t) => t.id)).toEqual(['note:research/A.md'])
    expect(done.reloadToken).toBe(opened.reloadToken + 1)
  })
})

describe('a terminal started for a task', () => {
  it('says the task in its title and remembers it for the session that is asked for', () => {
    const state = reduce(initialState, {
      type: 'openTerminal',
      kind: 'Claude',
      cwd: '/repo',
      id: 'a',
      task: 'rebuild-diff',
    })
    expect(state.terminals[0]).toMatchObject({
      title: 'Claude Code 1 · rebuild',
      cwd: '/repo',
      task: 'rebuild-diff',
    })
    const plain = reduce(state, { type: 'openTerminal', kind: 'Shell', cwd: '', id: 'b' })
    expect(plain.terminals[1]?.title).toBe('Shell 2')
    expect(plain.terminals[1]).not.toHaveProperty('task')
  })

  it('runs a command in a shell opened for it, with the tab called what it is for', () => {
    const state = reduce(initialState, {
      type: 'openTerminal',
      kind: 'Shell',
      cwd: '',
      id: 'a',
      command: 'npm install -g thing',
      title: 'Install Claude Code',
    })
    expect(state.terminals[0]).toMatchObject({
      kind: 'Shell',
      title: 'Install Claude Code',
      command: 'npm install -g thing',
    })
    // It counts as one of the terminals opened, so the next plain one is numbered after it.
    const plain = reduce(state, { type: 'openTerminal', kind: 'Shell', cwd: '', id: 'b' })
    expect(plain.terminals[1]?.title).toBe('Shell 2')
    expect(plain.terminals[1]).not.toHaveProperty('command')
  })
})

describe('the code graph page', () => {
  it('is one page, opened once and named', () => {
    expect(pageId({ kind: 'graph' })).toBe('graph')
    expect(pageTitle({ kind: 'graph' })).toBe('Code graph')
    const twice = reduce(reduce(initialState, { type: 'openPage', page: { kind: 'graph' } }), {
      type: 'openPage',
      page: { kind: 'graph' },
    })
    expect(twice.tabs).toHaveLength(1)
    expect(twice.activeId).toBe('graph')
  })
})

describe('the start', () => {
  it('has the home page open and active, and nothing else', () => {
    expect(startState.tabs).toEqual([{ id: 'home', page: { kind: 'home' } }])
    expect(startState.activeId).toBe('home')
    expect(pageId({ kind: 'home' })).toBe('home')
    expect(pageTitle({ kind: 'home' })).toBe('Home')
  })

  it('opens the home page once', () => {
    const twice = reduce(startState, { type: 'openPage', page: { kind: 'home' } })
    expect(twice.tabs).toHaveLength(1)
  })

  it('cannot close the home page, so that there is always a page to come back to', () => {
    expect(reduce(startState, { type: 'closeTab', id: 'home' })).toBe(startState)
    const more = reduce(startState, { type: 'openPage', page: { kind: 'graph' } })
    expect(reduce(more, { type: 'closeTab', id: 'home' })).toBe(more)
  })

  it('is the page that shows when the last of the others is closed', () => {
    const state = reduce(reduce(startState, { type: 'openPage', page: { kind: 'graph' } }), {
      type: 'openPage',
      page: { kind: 'launch' },
    })
    const closed = reduce(reduce(state, { type: 'closeTab', id: 'launch' }), {
      type: 'closeTab',
      id: 'graph',
    })
    expect(closed.tabs.map((t) => t.id)).toEqual(['home'])
    expect(closed.activeId).toBe('home')
  })
})

describe('side panel', () => {
  it('opens on the definitions section', () => {
    expect(initialState.section).toBe('definitions')
    expect(initialState.panelOpen).toBe(true)
  })

  it('hides when the showing section is chosen again and shows when another is chosen', () => {
    const hidden = run([{ type: 'selectSection', section: 'definitions' }])
    expect(hidden.panelOpen).toBe(false)

    const other = run([{ type: 'selectSection', section: 'executions' }], hidden)
    expect(other).toMatchObject({ section: 'executions', panelOpen: true })
  })

  it('switches section without hiding when the panel is closed', () => {
    const closed = run([{ type: 'togglePanel' }])
    const next = run([{ type: 'selectSection', section: 'definitions' }], closed)
    expect(next.panelOpen).toBe(true)
  })
})

describe('page ids', () => {
  it('keeps a pipeline and an agent of the same name apart', () => {
    const a = {
      kind: 'definition',
      definition: 'pipeline',
      name: 'X',
      path: '/a/X.synapse',
    } as const
    const b = { kind: 'definition', definition: 'agent', name: 'X', path: '/b/X.synapse' } as const
    expect(pageId(a)).not.toBe(pageId(b))
  })

  it('opens an execution once', () => {
    const state = run([
      { type: 'openPage', page: { kind: 'execution', id: 'exec-1' } },
      { type: 'openPage', page: { kind: 'execution', id: 'exec-1' } },
    ])
    expect(state.tabs).toHaveLength(1)
  })
})

describe('a definition that is made', () => {
  const made = {
    kind: 'definition',
    definition: 'agent',
    name: 'Fresh',
    path: '/d/Fresh.synapse',
  } as const

  it('gives its create tab way to its page and has the lists read again', () => {
    const before = run([
      { type: 'openPage', page: settings },
      { type: 'openPage', page: newAgent },
    ])
    const after = reduce(before, { type: 'definitionCreated', closeId: 'create:agent', page: made })
    expect(after.tabs.map((t) => t.id)).toEqual(['settings:general', 'definition:agent:Fresh'])
    expect(after.activeId).toBe('definition:agent:Fresh')
    expect(after.reloadToken).toBe(before.reloadToken + 1)
  })
})

describe('a definition that is changed', () => {
  it('has the lists read again and leaves the tabs as they are', () => {
    const before = reduce(initialState, { type: 'openPage', page: settings })
    const after = reduce(before, { type: 'definitionsChanged' })
    expect(after.tabs).toEqual(before.tabs)
    expect(after.activeId).toBe(before.activeId)
    expect(after.reloadToken).toBe(before.reloadToken + 1)
  })
})

describe('settings pages', () => {
  it('are a page for each category, with a title of its own, opened once', () => {
    const vault = { kind: 'settings', section: 'vault' } as const
    const graph = { kind: 'settings', section: 'graph' } as const
    expect(pageId(vault)).toBe('settings:vault')
    expect(pageTitle(vault)).toBe('Vault settings')
    expect(pageTitle(graph)).toBe('Code graph settings')
    const opened = [vault, graph, vault].reduce(
      (state, page) => reduce(state, { type: 'openPage', page }),
      initialState,
    )
    expect(opened.tabs.map((t) => t.id)).toEqual(['settings:vault', 'settings:graph'])
    expect(opened.activeId).toBe('settings:vault')
  })

  it('have a title and a line about them in the panel for every category', () => {
    expect(SETTINGS_SECTIONS.map((s) => s.section)).toEqual([
      'general',
      'vault',
      'conventions',
      'graph',
      'environment',
      'integrations',
      'terminals',
    ])
    for (const { label, about } of SETTINGS_SECTIONS) {
      expect(label).not.toBe('')
      expect(about).not.toBe('')
    }
  })
})

describe('the vault status page', () => {
  it('is one page, called Vault, that puts the side panel on the vault', () => {
    const page = { kind: 'vault' } as const
    expect(pageId(page)).toBe('vault')
    expect(pageTitle(page)).toBe('Vault')
    const opened = reduce(reduce(initialState, { type: 'openPage', page }), {
      type: 'openPage',
      page,
    })
    expect(opened.tabs.map((t) => t.id)).toEqual(['vault'])
    expect(opened.section).toBe('vault')
    expect(sectionOf(page)).toEqual({ section: 'vault' })
  })
})

describe('terminals', () => {
  const open = (state: ShellState, id: string, kind: 'Shell' | 'Claude' = 'Shell', cwd = '') =>
    reduce(state, { type: 'openTerminal', kind, cwd, id })

  it('are sessions on one page, each with a title of its own, the newest selected', () => {
    const state = open(open(open(initialState, 'a'), 'b'), 'c', 'Claude', '/work')
    expect(state.tabs.map((t) => t.id)).toEqual(['terminals'])
    expect(state.activeId).toBe('terminals')
    expect(state.terminals.map((t) => [t.id, t.title, t.cwd])).toEqual([
      ['a', 'Shell 1', ''],
      ['b', 'Shell 2', ''],
      ['c', 'Claude Code 3', '/work'],
    ])
    expect(state.activeTerminal).toBe('c')
    expect(pageId({ kind: 'terminals' })).toBe('terminals')
    expect(pageTitle({ kind: 'terminals' })).toBe('Terminals')
  })

  it('are selected by id, and a session that is not there is left alone', () => {
    const state = open(open(initialState, 'a'), 'b')
    expect(reduce(state, { type: 'selectTerminal', id: 'a' }).activeTerminal).toBe('a')
    expect(reduce(state, { type: 'selectTerminal', id: 'zz' })).toBe(state)
  })

  it('leave the selection alone when a run is selected: a run is not among the terminals', () => {
    const state = reduce(open(initialState, 'a'), {
      type: 'openTerminal',
      kind: 'Pipeline',
      cwd: '',
      id: 'r',
      pipeline: 'Develop',
    })
    expect(state.activeTerminal).toBe('a')
    expect(reduce(state, { type: 'selectTerminal', id: 'r' })).toBe(state)
    // Closing the last shell closes the page, though a run's session is still there.
    const closed = reduce(state, { type: 'closeTerminal', id: 'a' })
    expect(closed.terminals.map((t) => t.id)).toEqual(['r'])
    expect(closed.activeTerminal).toBeNull()
    expect(closed.tabs.some((t) => t.id === 'terminals')).toBe(false)
  })

  it('are put in another order, within the list, and the selection stays', () => {
    const three = open(open(open(initialState, 'a'), 'b'), 'c')
    const ids = (s: typeof three) => s.terminals.map((t) => t.id)
    const moved = reduce(three, { type: 'moveTerminal', id: 'c', to: 0 })
    expect(ids(moved)).toEqual(['c', 'a', 'b'])
    expect(moved.activeTerminal).toBe(three.activeTerminal)
    expect(ids(reduce(three, { type: 'moveTerminal', id: 'a', to: 99 }))).toEqual(['b', 'c', 'a'])
    expect(ids(reduce(three, { type: 'moveTerminal', id: 'b', to: -5 }))).toEqual(['b', 'a', 'c'])
    // Nowhere new, or a session that is not there, leaves the state alone.
    expect(reduce(three, { type: 'moveTerminal', id: 'b', to: 1 })).toBe(three)
    expect(reduce(three, { type: 'moveTerminal', id: 'zz', to: 0 })).toBe(three)
  })

  it('give their place to a neighbour when the selected one closes, and go away with the last', () => {
    const three = open(open(open(initialState, 'a'), 'b'), 'c')
    const middle = reduce(reduce(three, { type: 'selectTerminal', id: 'b' }), {
      type: 'closeTerminal',
      id: 'b',
    })
    expect(middle.terminals.map((t) => t.id)).toEqual(['a', 'c'])
    expect(middle.activeTerminal).toBe('c')
    // A session that is not selected closing does not move the selection.
    expect(reduce(three, { type: 'closeTerminal', id: 'a' }).activeTerminal).toBe('c')

    const last = reduce(open(initialState, 'only'), { type: 'closeTerminal', id: 'only' })
    expect(last.terminals).toEqual([])
    expect(last.activeTerminal).toBeNull()
    expect(last.tabs).toEqual([])
  })

  it('end with the page: closing its tab closes every session', () => {
    const state = reduce(open(open(initialState, 'a'), 'b'), { type: 'closeTab', id: 'terminals' })
    expect(state.terminals).toEqual([])
    expect(state.activeTerminal).toBeNull()
  })

  it('keep an interactive run that is going on when the page is closed, and end the rest', () => {
    const run = reduce(open(initialState, 'a'), {
      type: 'openTerminal',
      kind: 'Pipeline',
      cwd: '',
      id: 'r',
      title: 'Develop',
      pipeline: 'Develop',
      input: 'fix it',
    })
    expect(run.terminals.find((t) => t.id === 'r')).toMatchObject({
      kind: 'Pipeline',
      pipeline: 'Develop',
      input: 'fix it',
      title: 'Develop',
    })
    const closed = reduce(run, { type: 'closeTab', id: 'terminals' })
    expect(closed.terminals.map((t) => t.id)).toEqual(['r'])
    // A run is not among the terminals, so none of them is selected.
    expect(closed.activeTerminal).toBeNull()
    expect(closed.tabs.some((t) => t.id === 'terminals')).toBe(false)
    // Once it has ended, closing the page lets it go.
    const ended = reduce(reduce(run, { type: 'terminalEnded', id: 'r' }), {
      type: 'closeTab',
      id: 'terminals',
    })
    expect(ended.terminals).toEqual([])
    expect(ended.activeTerminal).toBeNull()
  })

  it('learn the id of the run they started, once', () => {
    const run = reduce(initialState, {
      type: 'openTerminal',
      kind: 'Pipeline',
      cwd: '',
      id: 'r',
      pipeline: 'Develop',
    })
    const told = reduce(run, { type: 'terminalRun', id: 'r', executionId: 'exec-1' })
    expect(told.terminals[0]?.executionId).toBe('exec-1')
    expect(reduce(told, { type: 'terminalRun', id: 'r', executionId: 'exec-2' })).toBe(told)
    expect(reduce(told, { type: 'terminalRun', id: 'other', executionId: 'x' })).toBe(told)
  })

  it('of a pipeline open a page of their own, and leave the terminals alone', () => {
    const shell = reduce(initialState, { type: 'openTerminal', kind: 'Shell', cwd: '', id: 's' })
    const run = reduce(shell, {
      type: 'openTerminal',
      kind: 'Pipeline',
      cwd: '',
      id: 'r',
      pipeline: 'Develop',
    })
    expect(run.tabs.map((t) => t.id)).toEqual(['terminals', 'run-starting:r'])
    expect(run.activeId).toBe('run-starting:r')
    expect(run.activeTerminal).toBe('s')
    expect(run.terminals.map((t) => t.id)).toEqual(['s', 'r'])
    const alone = reduce(initialState, {
      type: 'openTerminal',
      kind: 'Pipeline',
      cwd: '',
      id: 'r',
      pipeline: 'Develop',
    })
    expect(alone.tabs.map((t) => t.id)).toEqual(['run-starting:r'])
    expect(alone.activeTerminal).toBeNull()
  })

  it('of a pipeline swap their page for the execution page once the run is named', () => {
    const run = reduce(reduce(initialState, { type: 'openPage', page: { kind: 'launch' } }), {
      type: 'openTerminal',
      kind: 'Pipeline',
      cwd: '',
      id: 'r',
      pipeline: 'Develop',
    })
    const told = reduce(run, { type: 'terminalRun', id: 'r', executionId: 'exec-1' })
    expect(told.tabs.map((t) => t.id)).toEqual(['launch', 'execution:exec-1'])
    expect(told.activeId).toBe('execution:exec-1')
    expect(told.terminals[0]?.executionId).toBe('exec-1')
  })

  it('of a pipeline keep the page that shows when the run is named behind another tab', () => {
    const run = reduce(
      reduce(initialState, { type: 'openTerminal', kind: 'Pipeline', cwd: '', id: 'r' }),
      { type: 'openPage', page: { kind: 'launch' } },
    )
    const told = reduce(run, { type: 'terminalRun', id: 'r', executionId: 'exec-1' })
    expect(told.tabs.map((t) => t.id)).toEqual(['execution:exec-1', 'launch'])
    expect(told.activeId).toBe('launch')
  })

  it('learn the run they started without a page for it, and change only that', () => {
    const run = reduce(initialState, {
      type: 'openTerminal',
      kind: 'Pipeline',
      cwd: '',
      id: 'r',
      pipeline: 'Develop',
    })
    const closed = { ...run, tabs: run.tabs.filter((t) => t.id !== 'run-starting:r') }
    const told = reduce(closed, { type: 'terminalRun', id: 'r', executionId: 'exec-1' })
    expect(told.terminals[0]?.executionId).toBe('exec-1')
    expect(told.tabs).toBe(closed.tabs)
    expect(told.activeId).toBe(closed.activeId)
  })

  it('let go of the session of a run that is starting when its page is closed', () => {
    const run = reduce(initialState, {
      type: 'openTerminal',
      kind: 'Pipeline',
      cwd: '',
      id: 'r',
      pipeline: 'Develop',
    })
    const closed = reduce(run, { type: 'closeTab', id: 'run-starting:r' })
    expect(closed.terminals).toEqual([])
    expect(closed.tabs).toEqual([])
    expect(closed.activeId).toBeNull()
  })

  it('name a run that is starting after its pipeline', () => {
    const page = { kind: 'run-starting', session: 'r' } as const
    const run = reduce(initialState, {
      type: 'openTerminal',
      kind: 'Pipeline',
      cwd: '',
      id: 'r',
      pipeline: 'Develop',
    })
    expect(tabTitle(page, run.terminals)).toBe('Develop')
    expect(tabTitle(page, [])).toBe('Starting run')
    expect(tabTitle({ kind: 'graph' }, [])).toBe('Code graph')
  })

  it('never give two sessions the same title, even after one closes', () => {
    const state = open(
      reduce(open(open(initialState, 'a'), 'b'), { type: 'closeTerminal', id: 'b' }),
      'c',
    )
    expect(state.terminals.map((t) => t.title)).toEqual(['Shell 1', 'Shell 3'])
  })

  it('are started from a page of their own, which is a tab like the others', () => {
    const state = reduce(initialState, { type: 'openPage', page: { kind: 'launch' } })
    expect(state.tabs.map((t) => t.id)).toEqual(['launch'])
    expect(state.activeId).toBe('launch')
    expect(pageTitle({ kind: 'launch' })).toBe('New terminal')
  })

  it('can continue a session of the harness, which the session keeps', () => {
    const state = reduce(initialState, {
      type: 'openTerminal',
      kind: 'Claude',
      cwd: '/work',
      id: 'a',
      resume: 'abc-123',
    })
    expect(state.terminals[0]).toMatchObject({ kind: 'Claude', cwd: '/work', resume: 'abc-123' })
    const plain = reduce(initialState, { type: 'openTerminal', kind: 'Shell', cwd: '', id: 'b' })
    expect(plain.terminals[0]).not.toHaveProperty('resume')
  })

  it('stay in their own tab when another one is started from the launch page', () => {
    const state = reduce(reduce(initialState, { type: 'openPage', page: { kind: 'launch' } }), {
      type: 'openTerminal',
      kind: 'Claude',
      cwd: '/work',
      id: 'a',
    })
    expect(state.tabs.map((t) => t.id)).toEqual(['launch', 'terminals'])
    expect(state.activeId).toBe('terminals')
    expect(state.terminals.map((t) => t.cwd)).toEqual(['/work'])
  })
})

describe('tabs', () => {
  it('opens a page once and activates it again instead of duplicating it', () => {
    const state = run([
      { type: 'openPage', page: settings },
      { type: 'openPage', page: newPipeline },
      { type: 'openPage', page: settings },
    ])
    expect(state.tabs.map((t) => t.id)).toEqual(['settings:general', 'create:pipeline'])
    expect(state.activeId).toBe('settings:general')
  })

  it('gives each kind of definition its own create tab', () => {
    expect(pageId(newPipeline)).not.toBe(pageId(newAgent))
  })

  it('activates only a tab that exists', () => {
    const state = run([{ type: 'openPage', page: settings }])
    expect(run([{ type: 'activateTab', id: 'nope' }], state).activeId).toBe('settings:general')
  })

  it('closing the active tab activates the one that took its place', () => {
    const state = run([
      { type: 'openPage', page: settings },
      { type: 'openPage', page: newPipeline },
      { type: 'openPage', page: newAgent },
      { type: 'activateTab', id: 'create:pipeline' },
      { type: 'closeTab', id: 'create:pipeline' },
    ])
    expect(state.activeId).toBe('create:agent')
  })

  it('closing the last tab of the row activates the one before it', () => {
    const state = run([
      { type: 'openPage', page: settings },
      { type: 'openPage', page: newPipeline },
      { type: 'closeTab', id: 'create:pipeline' },
    ])
    expect(state.activeId).toBe('settings:general')
  })

  it('closing a tab that is not active keeps the active one', () => {
    const state = run([
      { type: 'openPage', page: settings },
      { type: 'openPage', page: newPipeline },
      { type: 'closeTab', id: 'settings' },
    ])
    expect(state.activeId).toBe('create:pipeline')
  })

  it('closing the only tab leaves none active', () => {
    const state = run([
      { type: 'openPage', page: settings },
      { type: 'closeTab', id: 'settings:general' },
    ])
    expect(state).toMatchObject({ tabs: [], activeId: null })
  })
})

describe('tabs', () => {
  const open = (state: ShellState, ...names: string[]) =>
    names.reduce(
      (s, name) => reduce(s, { type: 'openPage', page: { kind: 'note', path: `${name}.md` } }),
      state,
    )
  const ids = (state: ShellState) => state.tabs.map((t) => t.id)
  const home = reduce(initialState, { type: 'openPage', page: { kind: 'home' } })

  it('can be moved, to an index of the list once the tab is taken out', () => {
    const state = open(home, 'a', 'b', 'c')
    expect(ids(state)).toEqual(['home', 'note:a.md', 'note:b.md', 'note:c.md'])
    expect(ids(reduce(state, { type: 'moveTab', id: 'note:c.md', to: 1 }))).toEqual([
      'home',
      'note:c.md',
      'note:a.md',
      'note:b.md',
    ])
    expect(ids(reduce(state, { type: 'moveTab', id: 'note:a.md', to: 3 }))).toEqual([
      'home',
      'note:b.md',
      'note:c.md',
      'note:a.md',
    ])
  })

  it('never go before the Home tab, and the Home tab is not moved', () => {
    const state = open(home, 'a', 'b')
    expect(ids(reduce(state, { type: 'moveTab', id: 'note:b.md', to: 0 }))).toEqual([
      'home',
      'note:b.md',
      'note:a.md',
    ])
    expect(reduce(state, { type: 'moveTab', id: 'home', to: 2 })).toBe(state)
  })

  it('keep the state when a tab is put where it is, or is not there', () => {
    const state = open(home, 'a', 'b')
    expect(reduce(state, { type: 'moveTab', id: 'note:a.md', to: 1 })).toBe(state)
    expect(reduce(state, { type: 'moveTab', id: 'note:nope.md', to: 1 })).toBe(state)
  })

  it('keep the active tab when another is moved', () => {
    const state = reduce(open(home, 'a', 'b'), { type: 'activateTab', id: 'note:a.md' })
    expect(reduce(state, { type: 'moveTab', id: 'note:b.md', to: 1 }).activeId).toBe('note:a.md')
  })

  it('note a session the host holds, once, so that its view attaches when it is made again', () => {
    const state = reduce(initialState, { type: 'openTerminal', kind: 'Shell', cwd: '', id: 'a' })
    expect(state.terminals[0]?.attach).toBeUndefined()
    const claimed = reduce(state, { type: 'terminalClaimed', id: 'a' })
    expect(claimed.terminals[0]?.attach).toBe(true)
    expect(reduce(claimed, { type: 'terminalClaimed', id: 'a' })).toBe(claimed)
    expect(reduce(state, { type: 'terminalClaimed', id: 'nope' })).toBe(state)
  })

  it('name a session, show the name, and give it back its title when the name is blank', () => {
    const state = reduce(initialState, { type: 'openTerminal', kind: 'Shell', cwd: '', id: 'a' })
    const title = state.terminals[0]?.title ?? ''
    const named = reduce(state, { type: 'renameTerminal', id: 'a', name: '  build  ' })
    expect(named.terminals[0]?.name).toBe('build')
    expect(terminalName(named.terminals[0]!)).toBe('build')
    // The title the host was given stays what it was.
    expect(named.terminals[0]?.title).toBe(title)
    expect(reduce(named, { type: 'renameTerminal', id: 'a', name: 'build' })).toBe(named)
    const unnamed = reduce(named, { type: 'renameTerminal', id: 'a', name: '  ' })
    expect(unnamed.terminals[0]).not.toHaveProperty('name')
    expect(terminalName(unnamed.terminals[0]!)).toBe(title)
    expect(reduce(state, { type: 'renameTerminal', id: 'nope', name: 'x' })).toBe(state)
  })

  it('note a session whose program ended, once', () => {
    const state = reduce(initialState, { type: 'openTerminal', kind: 'Shell', cwd: '', id: 'a' })
    const ended = reduce(state, { type: 'terminalEnded', id: 'a' })
    expect(ended.terminals[0]?.ended).toBe(true)
    expect(reduce(ended, { type: 'terminalEnded', id: 'a' })).toBe(ended)
    expect(reduce(state, { type: 'terminalEnded', id: 'nope' })).toBe(state)
  })
})

describe('the side panel', () => {
  it('is put open or shut, and is the same state when it already is', () => {
    const open = reduce(initialState, { type: 'setPanel', open: true })
    expect(open.panelOpen).toBe(true)
    const shut = reduce(open, { type: 'setPanel', open: false })
    expect(shut.panelOpen).toBe(false)
    expect(reduce(shut, { type: 'setPanel', open: false })).toBe(shut)
  })
})

describe('the side panel following the page', () => {
  const note = { kind: 'note', path: 'research/A.md' } as const
  const definition = { kind: 'definition', definition: 'agent', name: 'Dev', path: '/x' } as const
  const base = { ...initialState, section: 'definitions', panelOpen: true } as ShellState

  it('is on the vault for a note, on the executions for a run, and on the kind of a definition', () => {
    expect(reduce(base, { type: 'openPage', page: note }).section).toBe('vault')
    expect(reduce(base, { type: 'openPage', page: { kind: 'execution', id: 'r1' } }).section).toBe(
      'executions',
    )
    const opened = reduce(base, { type: 'openPage', page: definition })
    expect(opened.section).toBe('definitions')
    expect(opened.definitionKind).toBe('agent')
    expect(
      reduce(base, { type: 'openPage', page: { kind: 'settings', section: 'vault' } }).section,
    ).toBe('settings')
    expect(reduce(base, { type: 'openPage', page: { kind: 'new-note' } }).section).toBe('vault')
  })

  it('shows the kind of a definition that is being made', () => {
    const state = reduce(base, { type: 'openPage', page: { kind: 'create', definition: 'skill' } })
    expect(state.section).toBe('definitions')
    expect(state.definitionKind).toBe('skill')
  })

  it('is left where it was by the pages that belong to no section', () => {
    const onVault = { ...base, section: 'vault' } as ShellState
    for (const page of [
      { kind: 'home' },
      { kind: 'graph' },
      { kind: 'launch' },
      { kind: 'terminals' },
    ] as const) {
      expect(reduce(onVault, { type: 'openPage', page }).section).toBe('vault')
    }
  })

  it('does not open a panel that is shut, and does not shut one that is open', () => {
    const shut = { ...base, panelOpen: false } as ShellState
    const shown = reduce(shut, { type: 'openPage', page: note })
    expect(shown.section).toBe('vault')
    expect(shown.panelOpen).toBe(false)
    expect(reduce(base, { type: 'openPage', page: note }).panelOpen).toBe(true)
  })

  it('goes with the tab that is chosen, and with the tab that takes the place of a closed one', () => {
    const both = reduce(reduce(base, { type: 'openPage', page: note }), {
      type: 'openPage',
      page: { kind: 'execution', id: 'r1' },
    })
    expect(both.section).toBe('executions')
    expect(reduce(both, { type: 'activateTab', id: 'note:research/A.md' }).section).toBe('vault')
    expect(reduce(both, { type: 'closeTab', id: 'execution:r1' }).section).toBe('vault')
  })

  it('does not undo the person choosing another section for the page that is showing', () => {
    const state = reduce(base, { type: 'openPage', page: note })
    expect(reduce(state, { type: 'selectSection', section: 'executions' }).section).toBe(
      'executions',
    )
  })
})

describe('the Changes sidebar', () => {
  it('is shut when the app starts, and a toggle opens it and shuts it again', () => {
    expect(startState.changesOpen).toBe(false)
    const open = reduce(startState, { type: 'toggleChanges' })
    expect(open.changesOpen).toBe(true)
    expect(reduce(open, { type: 'toggleChanges' }).changesOpen).toBe(false)
  })

  it('is opened on the whole of what is looked at by asking to see the changes', () => {
    const shown = reduce(startState, { type: 'showChanges' })
    expect(shown).toMatchObject({ changesOpen: true, changesFile: null })
    expect(shown).not.toHaveProperty('changesVisit')
    expect(reduce(shown, { type: 'toggleChanges' }).changesOpen).toBe(false)
  })

  it('remembers what a session was compared with, for that session only', () => {
    const chosen = reduce(startState, { type: 'setChangesBase', session: 's1', base: 'commit' })
    expect(chosen.changesBases).toEqual({ s1: 'commit' })
    expect(
      reduce(chosen, { type: 'setChangesBase', session: 's2', base: 'start' }).changesBases,
    ).toEqual({ s1: 'commit', s2: 'start' })
  })

  it('remembers the tab, the commit and the kinds of each session, and lets them go with the session', () => {
    let state = reduce(startState, { type: 'openTerminal', kind: 'Shell', cwd: '/w', id: 's1' })
    state = reduce(state, { type: 'openTerminal', kind: 'Shell', cwd: '/w', id: 's2' })
    state = reduce(state, { type: 'setChangesTab', session: 's1', tab: 'git' })
    state = reduce(state, { type: 'setGitCommit', session: 's1', commit: 'abc1234' })
    state = reduce(state, { type: 'setChangesTab', session: 's2', tab: 'changes' })
    expect(state.changesTabs).toEqual({ s1: 'git', s2: 'changes' })
    expect(state.gitCommits).toEqual({ s1: 'abc1234' })
    expect(reduce(state, { type: 'setGitCommit', session: 's1', commit: null }).gitCommits).toEqual(
      {
        s1: null,
      },
    )
    state = reduce(state, { type: 'setActivityKinds', session: 's1', kinds: ['edit', 'write'] })
    expect(state.activityKinds).toEqual({ s1: ['edit', 'write'] })
    const closed = reduce(state, { type: 'closeTerminal', id: 's1' })
    expect(closed.changesTabs).toEqual({ s2: 'changes' })
    expect(closed.gitCommits).toEqual({})
    expect(closed.activityKinds).toEqual({})
  })

  it('is opened at a file when an activity names it, and asking for all of them lets it go', () => {
    const shown = reduce(startState, { type: 'showChanges', path: '/w/src/a.txt' })
    expect(shown).toMatchObject({ changesOpen: true, changesFile: '/w/src/a.txt' })
    expect(reduce(shown, { type: 'showChanges' }).changesFile).toBeNull()
  })
})

describe('the run dialog', () => {
  const opened = run([{ type: 'openPage', page: settings }], startState)

  it('is shut when the app starts', () => {
    expect(startState.runDialog).toBeNull()
  })

  it('opens for a pipeline over the page that is showing, and leaves the tabs as they were', () => {
    const state = reduce(opened, { type: 'openRunDialog', pipeline: 'Develop_Feature' })
    expect(state.runDialog).toBe('Develop_Feature')
    expect(state.tabs).toBe(opened.tabs)
    expect(state.activeId).toBe(opened.activeId)
    expect(state.section).toBe(opened.section)
  })

  it('opened for another pipeline takes the place of the one that was open', () => {
    const state = run(
      [
        { type: 'openRunDialog', pipeline: 'Develop_Feature' },
        { type: 'openRunDialog', pipeline: 'Fix_Bug' },
      ],
      opened,
    )
    expect(state.runDialog).toBe('Fix_Bug')
  })

  it('is shut again', () => {
    const state = run(
      [{ type: 'openRunDialog', pipeline: 'Develop_Feature' }, { type: 'closeRunDialog' }],
      opened,
    )
    expect(state.runDialog).toBeNull()
    expect(state.tabs).toBe(opened.tabs)
  })
})

describe('removed executions', () => {
  const opened = run(
    [
      { type: 'openPage', page: { kind: 'execution', id: 'r1' } },
      { type: 'openPage', page: { kind: 'execution', id: 'r2' } },
      { type: 'openPage', page: { kind: 'execution', id: 'r3' } },
      { type: 'activateTab', id: 'execution:r3' },
    ],
    startState,
  )

  it('closes the tabs of the removed runs and leaves another run alone', () => {
    const next = reduce(opened, { type: 'executionsRemoved', ids: ['r1', 'r2'] })
    expect(next.tabs.map((t) => t.id)).toEqual(['home', 'execution:r3'])
    expect(next.activeId).toBe('execution:r3')
  })

  it('moves the active tab as closing it would', () => {
    const onR2 = reduce(opened, { type: 'activateTab', id: 'execution:r2' })
    const next = reduce(onR2, { type: 'executionsRemoved', ids: ['r2'] })
    expect(next.tabs.map((t) => t.id)).toEqual(['home', 'execution:r1', 'execution:r3'])
    expect(next.activeId).toBe(reduce(onR2, { type: 'closeTab', id: 'execution:r2' }).activeId)
    expect(next.activeId).toBe('execution:r3')
  })

  it('changes nothing for ids with no open tab', () => {
    expect(reduce(opened, { type: 'executionsRemoved', ids: ['gone', 'other'] })).toEqual(opened)
  })
})
