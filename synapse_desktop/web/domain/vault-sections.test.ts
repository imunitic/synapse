import { describe, expect, it } from 'vitest'
import type { AttentionGroup } from './attention.ts'
import { noteCount, vaultSections } from './vault-sections.ts'

const group = (key: string, count: number): AttentionGroup => ({
  key: `vault:${key}`,
  title: key,
  items: Array.from({ length: count }, (_, i) => ({
    key: `${key}:${i}`,
    id: null,
    label: `n${i}`,
    detail: null,
    target: null,
  })),
})

describe('the sections of the vault status', () => {
  it('put the design notes first and the task notes second, each with its own groups', () => {
    const sections = vaultSections([
      group('in_progress', 2),
      group('discussing', 1),
      group('open_questions', 3),
      group('awaiting_review', 1),
    ])
    expect(sections.map((s) => s.title)).toEqual(['Design notes', 'Task notes'])
    expect(sections[0]?.groups.map((g) => g.key)).toEqual([
      'vault:discussing',
      'vault:open_questions',
    ])
    expect(sections[1]?.groups.map((g) => g.key)).toEqual([
      'vault:in_progress',
      'vault:awaiting_review',
    ])
    expect(sections.map(noteCount)).toEqual([4, 3])
  })

  it('say what each group is, and leave out a section that has nothing', () => {
    const only = vaultSections([group('in_progress', 1)])
    expect(only.map((s) => s.key)).toEqual(['tasks'])
    expect(only[0]?.groups[0]?.about).toBe('Items still to do')
    expect(vaultSections([])).toEqual([])
  })

  it('keep a group it does not know, under Other, without a line about it', () => {
    const sections = vaultSections([group('discussing', 1), group('surprise', 1)])
    expect(sections.map((s) => s.key)).toEqual(['designs', 'other'])
    expect(sections[1]?.groups[0]?.about).toBeNull()
  })
})
