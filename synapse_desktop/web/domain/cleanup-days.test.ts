import { describe, expect, it } from 'vitest'
import { memoryStorage } from '../state/memory-storage.ts'
import { readCleanupDays, writeCleanupDays } from './cleanup-days.ts'

describe('the remembered number of days for a clean up', () => {
  it('is 30 when nothing was kept', () => {
    expect(readCleanupDays(memoryStorage())).toBe(30)
  })

  it('reads back a stored number', () => {
    const storage = memoryStorage()
    writeCleanupDays(storage, 7)
    expect(readCleanupDays(storage)).toBe(7)
  })

  it('is 30 when what was kept is not a whole number of at least 1', () => {
    for (const kept of ['abc', '0', '-3', '2.5', '']) {
      const storage = memoryStorage()
      storage.setItem('synapse.cleanupDays', kept)
      expect(readCleanupDays(storage)).toBe(30)
    }
  })

  it('is 30 when the storage throws, and a write to it does not throw', () => {
    const broken = {
      getItem: (): string | null => {
        throw new Error('denied')
      },
      setItem: (): void => {
        throw new Error('denied')
      },
    }
    expect(readCleanupDays(broken)).toBe(30)
    expect(() => writeCleanupDays(broken, 7)).not.toThrow()
  })
})
