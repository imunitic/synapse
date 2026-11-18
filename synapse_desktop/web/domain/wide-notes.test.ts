import { describe, expect, it } from 'vitest'
import type { Memory } from './recent.ts'
import { isWide, setWide } from './wide-notes.ts'

function memory(): Memory {
  const items = new Map<string, string>()
  return {
    getItem: (key) => items.get(key) ?? null,
    setItem: (key, value) => void items.set(key, value),
  }
}

describe('the notes shown wide', () => {
  it('are narrow until widened, each on its own, and narrow again when turned off', () => {
    const m = memory()
    expect(isWide('a.md', m)).toBe(false)
    setWide('a.md', true, m)
    expect(isWide('a.md', m)).toBe(true)
    expect(isWide('b.md', m)).toBe(false)
    setWide('a.md', true, m)
    setWide('a.md', false, m)
    expect(isWide('a.md', m)).toBe(false)
  })

  it('forget the oldest choice once more notes are widened than are kept', () => {
    const m = memory()
    for (let i = 0; i < 501; i++) setWide(`n${i}.md`, true, m)
    expect(isWide('n0.md', m)).toBe(false)
    expect(isWide('n1.md', m)).toBe(true)
    expect(isWide('n500.md', m)).toBe(true)
  })

  it('are all narrow when what was kept is not a list of paths', () => {
    const bad = memory()
    bad.setItem('synapse-desktop.wide-notes', 'not json')
    expect(isWide('a.md', bad)).toBe(false)
    bad.setItem('synapse-desktop.wide-notes', '{"a.md":true}')
    expect(isWide('a.md', bad)).toBe(false)
  })

  it('are left alone when the browser keeps nothing, or fails', () => {
    expect(isWide('a.md', null)).toBe(false)
    expect(() => setWide('a.md', true, null)).not.toThrow()
    const failing: Memory = {
      getItem: () => null,
      setItem: () => {
        throw new Error('full')
      },
    }
    expect(() => setWide('a.md', true, failing)).not.toThrow()
  })
})
