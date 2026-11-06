import { describe, expect, it } from 'vitest'
import { initialState, pageId, reduce, type Action, type ShellState } from './state.ts'

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
