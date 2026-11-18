import { describe, expect, it } from 'vitest'
import type { Memory } from './recent.ts'
import { storedName, storeName } from './terminal-names.ts'

function memory(): Memory {
  const items = new Map<string, string>()
  return {
    getItem: (key) => items.get(key) ?? null,
    setItem: (key, value) => void items.set(key, value),
  }
}

describe('the names given to terminal sessions', () => {
  it('are kept by session, trimmed, and forgotten when blank or null', () => {
    const m = memory()
    expect(storedName('a', m)).toBeNull()
    storeName('a', '  build  ', m)
    storeName('b', 'tests', m)
    expect(storedName('a', m)).toBe('build')
    expect(storedName('b', m)).toBe('tests')
    storeName('a', 'release', m)
    expect(storedName('a', m)).toBe('release')
    storeName('a', '   ', m)
    expect(storedName('a', m)).toBeNull()
    storeName('b', null, m)
    expect(storedName('b', m)).toBeNull()
  })

  it('forget the oldest once more sessions are named than are kept', () => {
    const m = memory()
    for (let i = 0; i < 201; i++) storeName(`s${i}`, `n${i}`, m)
    expect(storedName('s0', m)).toBeNull()
    expect(storedName('s1', m)).toBe('n1')
    expect(storedName('s200', m)).toBe('n200')
  })

  it('are none when what was kept is not a list of pairs', () => {
    const bad = memory()
    bad.setItem('synapse-desktop.terminal-names', 'not json')
    expect(storedName('a', bad)).toBeNull()
    bad.setItem('synapse-desktop.terminal-names', '[["a", 3], ["b"], "c", ["d", "kept"]]')
    expect(storedName('a', bad)).toBeNull()
    expect(storedName('d', bad)).toBe('kept')
  })

  it('are left alone when the browser keeps nothing, or fails', () => {
    expect(storedName('a', null)).toBeNull()
    expect(() => storeName('a', 'x', null)).not.toThrow()
    const failing: Memory = {
      getItem: () => null,
      setItem: () => {
        throw new Error('full')
      },
    }
    expect(() => storeName('a', 'x', failing)).not.toThrow()
  })
})
