import { describe, expect, it } from 'vitest'
import { DEVELOP_FEATURE_SHOW } from './fixtures.ts'
import { parseDescription, type PipelineDescription } from './pipelines.ts'
import { dataFieldsFor } from './step-data.ts'

const field = (name: string) => ({ name, type: 'string', required: true, description: `${name}.` })

function described(): PipelineDescription {
  const json = JSON.parse(DEVELOP_FEATURE_SHOW) as { steps: Record<string, unknown>[] }
  json.steps[2]!.data = { fields: [field('task_note')], checks: [] }
  json.steps[2]!.outcomes = [
    { word: 'Approved', meaning: 'Every requirement is met.', data: null },
    { word: 'Changes_Requested', meaning: 'Something is unmet.', data: [field('problems')] },
  ]
  const description = parseDescription(json)
  if (description === null) throw new Error('the fixture is not a description')
  return description
}

describe('dataFieldsFor', () => {
  it('lists step and outcome fields', () => {
    const description = described()
    const step = description.steps[2]!.name
    expect(dataFieldsFor(description, step, 'Changes_Requested').map((f) => f.name)).toEqual([
      'task_note',
      'problems',
    ])
  })

  it('an outcome without data adds nothing', () => {
    const description = described()
    const step = description.steps[2]!.name
    expect(dataFieldsFor(description, step, 'Approved').map((f) => f.name)).toEqual(['task_note'])
    expect(dataFieldsFor(description, step, 'Unknown_Word').map((f) => f.name)).toEqual([
      'task_note',
    ])
  })

  it('a step unknown to the description gives no fields', () => {
    expect(dataFieldsFor(described(), 'No_Such_Step', 'Approved')).toEqual([])
  })
})
