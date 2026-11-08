import { describe, expect, it } from 'vitest'
import { launchView, rememberLaunchView } from './launch-view.ts'
import type { Memory } from './recent.ts'

function memory(): Memory & { kept: Map<string, string> } {
  const kept = new Map<string, string>()
  return {
    kept,
    getItem: (key) => kept.get(key) ?? null,
    setItem: (key, value) => void kept.set(key, value),
  }
}

describe('the list a card was last showing', () => {
  it('is the folders until the sessions were chosen', () => {
    const m = memory()
    expect(launchView('Claude', m)).toBe('folders')
    rememberLaunchView('Claude', 'sessions', m)
    expect(launchView('Claude', m)).toBe('sessions')
    rememberLaunchView('Claude', 'folders', m)
    expect(launchView('Claude', m)).toBe('folders')
  })

  it('is kept for each harness on its own', () => {
    const m = memory()
    rememberLaunchView('Codex', 'sessions', m)
    expect(launchView('Codex', m)).toBe('sessions')
    expect(launchView('Claude', m)).toBe('folders')
    expect(launchView('Opencode', m)).toBe('folders')
  })

  it('is the folders for something else that was kept', () => {
    const m = memory()
    m.setItem('synapse-desktop.launch-view.Claude', 'whatever')
    expect(launchView('Claude', m)).toBe('folders')
  })

  it('is the folders when the browser keeps nothing, or throws', () => {
    expect(launchView('Claude', null)).toBe('folders')
    expect(() => rememberLaunchView('Claude', 'sessions', null)).not.toThrow()
    const broken: Memory = {
      getItem: () => {
        throw new Error('blocked')
      },
      setItem: () => {
        throw new Error('blocked')
      },
    }
    expect(launchView('Claude', broken)).toBe('folders')
    expect(() => rememberLaunchView('Claude', 'sessions', broken)).not.toThrow()
  })
})
