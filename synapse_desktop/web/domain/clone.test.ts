import { describe, expect, it } from 'vitest'
import { cloneName, cloneNameProblem, clonePipelineText } from './clone.ts'

describe('the name a clone is offered', () => {
  it('is the name with _Copy', () => {
    expect(cloneName('Develop_Feature')).toBe('Develop_Feature_Copy')
  })
})

describe("a cloned pipeline's text", () => {
  it('renames the header and a leading file comment', () => {
    const text =
      '\n-- Build.synapse\nPipeline   Build  {\n  Only [Harness => Claude, Prompt => "x"];\n}\n'
    expect(clonePipelineText(text, 'Build', 'Build_Copy')).toBe(
      '\n-- Build_Copy.synapse\nPipeline   Build_Copy  {\n  Only [Harness => Claude, Prompt => "x"];\n}\n',
    )
  })

  it('leaves a comment naming another file and a step or agent named like the pipeline alone', () => {
    const text = [
      '-- Other.synapse',
      '-- Build.synapse',
      'Pipeline Build {',
      '  Build [Agent => Build];',
      '}',
      'Pipeline Build {',
    ].join('\n')
    expect(clonePipelineText(text, 'Build', 'Ship')).toBe(
      [
        '-- Other.synapse',
        '-- Build.synapse',
        'Pipeline Ship {',
        '  Build [Agent => Build];',
        '}',
        'Pipeline Build {',
      ].join('\n'),
    )
  })

  it('renames only the header of a text without a header comment', () => {
    const text = 'Pipeline Build {\n  -- Build.synapse\n  Only [Agent => Builder];\n}'
    expect(clonePipelineText(text, 'Build', 'Ship')).toBe(
      'Pipeline Ship {\n  -- Build.synapse\n  Only [Agent => Builder];\n}',
    )
  })
})

describe("what is wrong with a clone's name", () => {
  const existing = [
    { name: 'Develop_Feature', kind: 'pipeline' as const },
    { name: 'Reviewer', kind: 'agent' as const },
  ]

  it('explains a name the schema refuses', () => {
    expect(cloneNameProblem('1bad', existing)).toBe(
      'A name has letters, digits and underscores, starts with a letter and is at most 128 characters.',
    )
  })

  it('names the kind of definition that has the name', () => {
    expect(cloneNameProblem('Reviewer', existing)).toBe('An agent called Reviewer already exists.')
  })

  it('is null for a free name', () => {
    expect(cloneNameProblem('Develop_Feature_Copy', existing)).toBeNull()
  })
})
