import { describe, expect, it } from 'vitest'
import { checkProblems, fieldReference, sampleInput, takesText } from './input-declaration.ts'
import type { InputDeclaration } from './pipelines.ts'

const declared: InputDeclaration = {
  fields: [
    { name: 'task_id', type: 'string', required: true, description: 'The task.' },
    { name: 'due', type: 'timestamp', required: false, description: 'When.' },
    { name: 'attempts', type: 'integer', required: false, description: 'How often.' },
    { name: 'draft', type: 'boolean', required: false, description: 'Draft only.' },
    { name: 'tags', type: 'list', required: false, description: 'Tags.', items: 'string' },
    {
      name: 'files',
      type: 'list',
      required: false,
      description: 'Files.',
      items: {
        fields: [{ name: 'path', type: 'string', required: true, description: 'A path.' }],
      },
    },
  ],
  checks: [],
  single_text_field: null,
}

describe('the sample input', () => {
  it('has every field in declared order with an empty value of its type', () => {
    const sample = sampleInput(declared)
    expect(Object.keys(JSON.parse(sample) as object)).toEqual([
      'task_id',
      'due',
      'attempts',
      'draft',
      'tags',
      'files',
    ])
    expect(JSON.parse(sample)).toEqual({
      task_id: '',
      due: '',
      attempts: 0,
      draft: false,
      tags: [],
      files: [],
    })
  })

  it('is pretty JSON with a two-space indent', () => {
    const one: InputDeclaration = {
      fields: [{ name: 'task_id', type: 'string', required: true, description: 'The task.' }],
      checks: [],
      single_text_field: 'task_id',
    }
    expect(sampleInput(one)).toBe('{\n  "task_id": ""\n}')
  })
})

describe('the field reference', () => {
  it('is one row per field, with list types spelled out', () => {
    expect(fieldReference(declared)).toEqual([
      { name: 'task_id', type: 'string', required: true, description: 'The task.' },
      { name: 'due', type: 'timestamp', required: false, description: 'When.' },
      { name: 'attempts', type: 'integer', required: false, description: 'How often.' },
      { name: 'draft', type: 'boolean', required: false, description: 'Draft only.' },
      { name: 'tags', type: 'list of string', required: false, description: 'Tags.' },
      { name: 'files', type: 'list of items', required: false, description: 'Files.' },
    ])
  })
})

describe('whether a sentence will do', () => {
  it('is true without a declaration', () => {
    expect(takesText(null)).toBe(true)
  })

  it('is true for a declaration with a single text field', () => {
    expect(takesText({ ...declared, single_text_field: 'task_id' })).toBe(true)
  })

  it('is false for a declaration without one', () => {
    expect(takesText(declared)).toBe(false)
  })
})

describe('the problems check --input reports', () => {
  it('are none for code 0', () => {
    expect(checkProblems({ code: 0, stdout: 'ok\n', stderr: 'warning: something\n' })).toEqual([])
  })

  it('are the error lines without their prefix for code 2', () => {
    const stderr = [
      'error: input.task_id: required field is missing',
      'error: input.extra: unknown field',
      '',
    ].join('\n')
    expect(checkProblems({ code: 2, stdout: '', stderr })).toEqual([
      'input.task_id: required field is missing',
      'input.extra: unknown field',
    ])
  })

  it('never include a warning', () => {
    const stderr = 'warning: a step has no outcomes\nerror: input: expected a JSON object\n'
    expect(checkProblems({ code: 2, stdout: '', stderr })).toEqual([
      'input: expected a JSON object',
    ])
  })

  it('are what was written when the check failed without an error line', () => {
    const stderr = 'usage: synapse-pipeline check <pipeline>\n'
    expect(checkProblems({ code: 64, stdout: '', stderr })).toEqual([
      'usage: synapse-pipeline check <pipeline>',
    ])
  })

  it('say the input could not be checked when the check failed silently', () => {
    expect(checkProblems({ code: 1, stdout: '', stderr: '' })).toEqual([
      'The input could not be checked.',
    ])
  })
})
