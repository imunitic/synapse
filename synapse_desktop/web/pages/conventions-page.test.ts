import { describe, expect, it } from 'vitest'
import { countLabel } from './ConventionsPage.tsx'

describe('the count of a card', () => {
  it('is said in the singular for one entry and the plural otherwise', () => {
    expect(countLabel(0)).toBe('0 entries')
    expect(countLabel(1)).toBe('1 entry')
    expect(countLabel(2)).toBe('2 entries')
  })
})
