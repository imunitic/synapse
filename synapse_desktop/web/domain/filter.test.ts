import { describe, expect, it } from 'vitest'
import { filterByName, matchesQuery } from './filter.ts'

describe('a filter', () => {
  it('holds a name that has every word, in any case, wherever they are', () => {
    expect(matchesQuery('Develop_Feature', 'feat')).toBe(true)
    expect(matchesQuery('Develop_Feature', 'FEAT dev')).toBe(true)
    expect(matchesQuery('Develop_Feature', 'ship')).toBe(false)
    expect(matchesQuery('Develop_Feature', 'dev ship')).toBe(false)
  })

  it('holds everything when it is empty or only spaces', () => {
    expect(matchesQuery('Anything', '')).toBe(true)
    expect(matchesQuery('Anything', '   ')).toBe(true)
  })

  it('keeps the items whose names it holds, in their order', () => {
    const items = [{ name: 'Developer' }, { name: 'Tester' }, { name: 'Reviewer' }]
    expect(filterByName(items, 'er').map((i) => i.name)).toEqual([
      'Developer',
      'Tester',
      'Reviewer',
    ])
    expect(filterByName(items, 'rev').map((i) => i.name)).toEqual(['Reviewer'])
    expect(filterByName(items, 'zzz')).toEqual([])
    expect(filterByName(items, '')).toHaveLength(3)
  })
})
