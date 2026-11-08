import { describe, expect, it } from 'vitest'
import { DEVELOP_FEATURE_SHOW } from './fixtures.ts'
import { fallThrough, routesFrom } from './outcomes.ts'
import { guardLabel, outcomeOf, type PipelineDescription } from './pipelines.ts'

const develop = JSON.parse(DEVELOP_FEATURE_SHOW) as PipelineDescription

describe('outcomeOf', () => {
  it('reads the outcome an edge waits for', () => {
    expect(outcomeOf({ '==': [{ var: 'outcome' }, 'Done'] })).toBe('Done')
  })

  it('finds none in another rule or in no guard', () => {
    expect(outcomeOf({ '>': [{ var: 'data.failing' }, 0] })).toBeNull()
    expect(outcomeOf({ '==': [{ var: 'summary' }, 'Done'] })).toBeNull()
    expect(outcomeOf(null)).toBeNull()
  })

  it('keeps guardLabel as it was', () => {
    expect(guardLabel({ '==': [{ var: 'outcome' }, 'Done'] })).toBe('Done')
    expect(guardLabel(null)).toBeNull()
  })
})

describe('routesFrom', () => {
  it('lists the edges that leave a real step, with the outcome and the bound', () => {
    expect(routesFrom(develop, 'Review')).toEqual([
      {
        edgeIndex: 0,
        to: 'Develop',
        outcome: 'Changes_Requested',
        rule: null,
        maxIterations: 5,
      },
    ])
  })

  it('lists nothing for a step that no edge leaves', () => {
    expect(routesFrom(develop, 'Develop')).toEqual([])
  })

  it('keeps another rule as JSON, and an edge with no guard as neither', () => {
    const description = {
      ...develop,
      edges: [
        {
          index: 0,
          from: 'A',
          to: 'B',
          guard: { '>': [{ var: 'data.n' }, 1] },
          max_iterations: null,
        },
        { index: 1, from: 'A', to: 'End', guard: null, max_iterations: null },
      ],
    }
    expect(routesFrom(description, 'A')).toMatchObject([
      { outcome: null, rule: '{">":[{"var":"data.n"},1]}' },
      { outcome: null, rule: null, to: 'End' },
    ])
  })
})

describe('fallThrough', () => {
  it('is the next declared step, and null after the last', () => {
    expect(fallThrough(develop, 'Develop')).toBe('Test')
    expect(fallThrough(develop, 'Review')).toBeNull()
  })
})
