import { describe, expect, it } from 'vitest'
import { initialState, pageId, pageTitle, reduce, type Action, type ShellState } from './state.ts'

function run(actions: Action[], from: ShellState = initialState): ShellState {
  return actions.reduce(reduce, from)
}

const settings = { kind: 'settings' } as const
const newPipeline = { kind: 'create', definition: 'pipeline' } as const
const newAgent = { kind: 'create', definition: 'agent' } as const

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
    expect(after.tabs.map((t) => t.id)).toEqual(['settings', 'definition:agent:Fresh'])
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

  it('never give two sessions the same title, even after one closes', () => {
    const state = open(
      reduce(open(open(initialState, 'a'), 'b'), { type: 'closeTerminal', id: 'b' }),
      'c',
    )
    expect(state.terminals.map((t) => t.title)).toEqual(['Shell 1', 'Shell 3'])
  })

  it('have a section in the rail that shows its panel', () => {
    const state = reduce(initialState, { type: 'selectSection', section: 'terminals' })
    expect(state.section).toBe('terminals')
    expect(state.panelOpen).toBe(true)
  })
})

describe('tabs', () => {
  it('opens a page once and activates it again instead of duplicating it', () => {
    const state = run([
      { type: 'openPage', page: settings },
      { type: 'openPage', page: newPipeline },
      { type: 'openPage', page: settings },
    ])
    expect(state.tabs.map((t) => t.id)).toEqual(['settings', 'create:pipeline'])
    expect(state.activeId).toBe('settings')
  })

  it('gives each kind of definition its own create tab', () => {
    expect(pageId(newPipeline)).not.toBe(pageId(newAgent))
  })

  it('activates only a tab that exists', () => {
    const state = run([{ type: 'openPage', page: settings }])
    expect(run([{ type: 'activateTab', id: 'nope' }], state).activeId).toBe('settings')
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
    expect(state.activeId).toBe('settings')
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
      { type: 'closeTab', id: 'settings' },
    ])
    expect(state).toMatchObject({ tabs: [], activeId: null })
  })
})
