import { describe, expect, it } from 'vitest'
import { parseEvents } from './executions.ts'
import { DEVELOP_FEATURE_SHOW, FAILED_EVENTS, LOOP_EVENTS } from './fixtures.ts'
import { progressOf, visitsOf } from './progress.ts'
import type { PipelineDescription } from './pipelines.ts'

const develop = JSON.parse(DEVELOP_FEATURE_SHOW) as PipelineDescription

describe('progressOf a run that looped once and completed', () => {
  const progress = progressOf(develop, parseEvents(LOOP_EVENTS), {
    status: 'completed',
    currentStep: null,
    failureStep: null,
    fired: [1],
  })

  it('counts the visits of each step', () => {
    expect(progress.steps['Develop']).toMatchObject({ visits: 2, state: 'done', outcome: 'Done' })
    expect(progress.steps['Test']).toMatchObject({ visits: 2, state: 'done' })
    expect(progress.steps['Review']).toMatchObject({
      visits: 2,
      state: 'done',
      outcome: 'Approved',
    })
  })

  it('counts the back edge as taken once', () => {
    expect(progress.arcCounts).toEqual({ 0: 1 })
  })

  it('counts the passes between neighbours that no edge made', () => {
    // Develop to Test and Test to Review happened twice each; Review is last.
    expect(progress.flowCounts).toEqual([2, 2, 1])
  })

  it('says the run reached its end by falling off the last step', () => {
    expect(progress.endReached).toBe(true)
    expect(progress.unknownSteps).toEqual([])
  })
})

describe('progressOf a run that failed', () => {
  const progress = progressOf(develop, parseEvents(FAILED_EVENTS), {
    status: 'failed',
    currentStep: null,
    failureStep: 'Test',
    fired: [0],
  })

  it('marks the step that failed and the one before it as done', () => {
    expect(progress.steps['Develop']?.state).toBe('done')
    expect(progress.steps['Test']?.state).toBe('failed')
    expect(progress.steps['Review']).toMatchObject({ state: 'idle', visits: 0 })
  })

  it('does not reach the end', () => {
    expect(progress.endReached).toBe(false)
    expect(progress.flowCounts).toEqual([1, 0, 0])
  })
})

describe('progressOf a run that is going or died', () => {
  const events = parseEvents(
    [
      '{"sequence":1,"kind":"run.started","step":"Develop","detail":{"pipeline":"P"}}',
      '{"sequence":2,"kind":"step.started","step":"Develop","detail":null}',
      '',
    ].join('\n'),
  )

  it('marks the step it is in as current', () => {
    const progress = progressOf(develop, events, {
      status: 'running',
      currentStep: 'Develop',
      failureStep: null,
      fired: [0],
    })
    expect(progress.steps['Develop']).toMatchObject({ state: 'current', visits: 1 })
  })

  it('marks it as interrupted when the run died there', () => {
    const progress = progressOf(develop, events, {
      status: 'interrupted',
      currentStep: 'Develop',
      failureStep: null,
      fired: [0],
    })
    expect(progress.steps['Develop']?.state).toBe('interrupted')
  })
})

describe('progressOf with a pipeline that has changed', () => {
  it('reports the steps of the events that the pipeline does not have', () => {
    const events = parseEvents('{"sequence":1,"kind":"step.started","step":"Gone","detail":null}\n')
    const progress = progressOf(develop, events, {
      status: 'completed',
      currentStep: null,
      failureStep: null,
      fired: [],
    })
    expect(progress.unknownSteps).toEqual(['Gone'])
  })
})

describe('visitsOf', () => {
  it('lists the visits in order, with the outcome and where control went', () => {
    const visits = visitsOf(parseEvents(LOOP_EVENTS))
    expect(visits).toHaveLength(6)
    expect(visits[2]).toEqual({
      n: 3,
      step: 'Review',
      outcome: 'Changes_Requested',
      next: 'Develop',
    })
    expect(visits[5]).toEqual({ n: 6, step: 'Review', outcome: 'Approved', next: null })
  })

  it('leaves the visit that is going on without an outcome', () => {
    const visits = visitsOf(
      parseEvents('{"sequence":1,"kind":"step.started","step":"Develop","detail":null}\n'),
    )
    expect(visits).toEqual([{ n: 1, step: 'Develop', outcome: null, next: null }])
  })
})
