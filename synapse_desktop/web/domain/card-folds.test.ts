import { describe, expect, it } from 'vitest'
import { readCardOpen, writeCardOpen } from './card-folds.ts'

describe('which cards are open', () => {
  function storage() {
    const held = new Map<string, string>()
    return {
      held,
      getItem: (key: string) => held.get(key) ?? null,
      setItem: (key: string, value: string) => void held.set(key, value),
      removeItem: (key: string) => void held.delete(key),
    }
  }

  const broken = {
    getItem: () => {
      throw new Error('no storage')
    },
    setItem: () => {
      throw new Error('no storage')
    },
    removeItem: () => {
      throw new Error('no storage')
    },
  }

  it('is the default while nothing is kept', () => {
    const s = storage()
    expect(readCardOpen(s, 'trace', false)).toBe(false)
    expect(readCardOpen(s, 'outcomes', true)).toBe(true)
  })

  it('is the kept choice, whatever the default', () => {
    const s = storage()
    s.setItem('card-open:trace', '1')
    s.setItem('card-open:outcomes', '0')
    expect(readCardOpen(s, 'trace', false)).toBe(true)
    expect(readCardOpen(s, 'trace', true)).toBe(true)
    expect(readCardOpen(s, 'outcomes', true)).toBe(false)
    expect(readCardOpen(s, 'outcomes', false)).toBe(false)
  })

  it('is the default for a value it does not know', () => {
    const s = storage()
    s.setItem('card-open:events', 'yes')
    expect(readCardOpen(s, 'events', false)).toBe(false)
    expect(readCardOpen(s, 'events', true)).toBe(true)
  })

  it('is the default where the storage cannot be read', () => {
    expect(readCardOpen(broken, 'trace', false)).toBe(false)
    expect(readCardOpen(broken, 'outcomes', true)).toBe(true)
  })

  it('forgets a choice that equals the default', () => {
    const s = storage()
    writeCardOpen(s, 'trace', true, false)
    writeCardOpen(s, 'trace', false, false)
    expect(s.held.size).toBe(0)
  })

  it('keeps a choice that differs from the default', () => {
    const s = storage()
    writeCardOpen(s, 'trace', true, false)
    writeCardOpen(s, 'outcomes', false, true)
    expect(s.held.get('card-open:trace')).toBe('1')
    expect(s.held.get('card-open:outcomes')).toBe('0')
  })

  it('does not throw where the storage cannot be written', () => {
    expect(() => writeCardOpen(broken, 'trace', true, false)).not.toThrow()
  })
})
