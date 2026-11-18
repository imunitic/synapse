import { describe, expect, it } from 'vitest'
import { recentlyOpened, recordOpened, type Memory } from './recent.ts'

function memory(): Memory & { items: Map<string, string> } {
  const items = new Map<string, string>()
  return {
    items,
    getItem: (key) => items.get(key) ?? null,
    setItem: (key, value) => void items.set(key, value),
  }
}

describe('the notes opened lately', () => {
  it('are newest first, each once, and no more than are kept', () => {
    const m = memory()
    for (const path of ['a.md', 'b.md', 'c.md', 'a.md']) recordOpened(path, m)
    expect(recentlyOpened(10, m)).toEqual(['a.md', 'c.md', 'b.md'])
    for (let i = 0; i < 30; i++) recordOpened(`n${i}.md`, m)
    expect(recentlyOpened(100, m)).toHaveLength(12)
    expect(recentlyOpened(3, m)).toEqual(['n29.md', 'n28.md', 'n27.md'])
  })

  it('are none when nothing was kept, or what was kept is not a list of paths', () => {
    expect(recentlyOpened(5, memory())).toEqual([])
    const bad = memory()
    bad.setItem('synapse-desktop.recent-notes', '{"not":"a list"}')
    expect(recentlyOpened(5, bad)).toEqual([])
    bad.setItem('synapse-desktop.recent-notes', 'not json')
    expect(recentlyOpened(5, bad)).toEqual([])
    bad.setItem('synapse-desktop.recent-notes', '["a.md", 3, null, "b.md"]')
    expect(recentlyOpened(5, bad)).toEqual(['a.md', 'b.md'])
  })

  it('are left alone when the browser keeps nothing, or fails', () => {
    expect(recentlyOpened(5, null)).toEqual([])
    expect(() => recordOpened('a.md', null)).not.toThrow()
    const failing: Memory = {
      getItem: () => null,
      setItem: () => {
        throw new Error('full')
      },
    }
    expect(() => recordOpened('a.md', failing)).not.toThrow()
  })
})
