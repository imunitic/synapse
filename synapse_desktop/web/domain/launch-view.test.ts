import { describe, expect, it } from 'vitest'
import { launchOpen, launchView, rememberLaunchOpen, rememberLaunchView } from './launch-view.ts'
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

describe('whether a card was open', () => {
  it('is open for the shell and shut for a harness until the person chose', () => {
    const m = memory()
    expect(launchOpen('Shell', m)).toBe(true)
    for (const harness of ['Claude', 'Codex', 'Opencode'] as const) {
      expect(launchOpen(harness, m)).toBe(false)
    }
  })

  it('is what the person left, for each card on its own and apart from the list a harness shows', () => {
    const m = memory()
    rememberLaunchOpen('Codex', true, m)
    rememberLaunchOpen('Shell', false, m)
    rememberLaunchView('Claude', 'sessions', m)
    expect(launchOpen('Codex', m)).toBe(true)
    expect(launchOpen('Shell', m)).toBe(false)
    expect(launchOpen('Claude', m)).toBe(false)
    expect(launchView('Codex', m)).toBe('folders')
    rememberLaunchOpen('Codex', false, m)
    expect(launchOpen('Codex', m)).toBe(false)
  })

  it('is the way it starts when the browser keeps nothing, throws, or keeps something else', () => {
    expect(launchOpen('Shell', null)).toBe(true)
    expect(launchOpen('Claude', null)).toBe(false)
    expect(() => rememberLaunchOpen('Shell', false, null)).not.toThrow()
    const m = memory()
    m.setItem('synapse-desktop.launch-open.Claude', 'whatever')
    expect(launchOpen('Claude', m)).toBe(false)
    const broken: Memory = {
      getItem: () => {
        throw new Error('blocked')
      },
      setItem: () => {
        throw new Error('blocked')
      },
    }
    expect(launchOpen('Shell', broken)).toBe(true)
    expect(launchOpen('Claude', broken)).toBe(false)
    expect(() => rememberLaunchOpen('Claude', true, broken)).not.toThrow()
  })
})
