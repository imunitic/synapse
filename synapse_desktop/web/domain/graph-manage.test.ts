import { describe, expect, it } from 'vitest'
import { dropQuestion, nothingToClean, parseDropSummary, removals } from './graph-manage.ts'

const plan = [
  'namespace: synapse/widget@main (2 nodes, 1 with ## Notes content)',
  'would-remove synapse/widget@main',
]

describe('a dry run', () => {
  it('says how many nodes there are and how many have Notes written by hand', () => {
    expect(parseDropSummary(plan)).toEqual({ nodes: 2, withNotes: 1 })
    expect(parseDropSummary(['namespace: x (1 node, 0 with ## Notes content)'])).toEqual({
      nodes: 1,
      withNotes: 0,
    })
    expect(parseDropSummary(['nothing to clean'])).toBeNull()
  })

  it('names what would be removed, and is empty when there is nothing', () => {
    expect(removals(plan)).toEqual(['synapse/widget@main'])
    expect(nothingToClean(plan)).toBe(false)
    expect(nothingToClean(['nothing to clean'])).toBe(true)
    expect(nothingToClean([])).toBe(true)
  })

  it('asks the question with the numbers, and keeps what was written by hand in view', () => {
    expect(dropQuestion('widget@main', plan)).toBe(
      'This deletes the graph of widget@main. Its 2 nodes will be removed from the vault, 1 of them with Notes written by hand, which are kept for a rebuild.',
    )
    expect(
      dropQuestion('a@b', ['namespace: x (1 node, 0 with ## Notes content)', 'would-remove x']),
    ).toBe('This deletes the graph of a@b. Its 1 node will be removed from the vault.')
    expect(dropQuestion('a@b', ['would-remove x'])).toBe('This deletes the graph of a@b.')
  })
})
