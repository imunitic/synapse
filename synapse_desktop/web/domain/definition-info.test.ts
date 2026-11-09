import { describe, expect, it } from 'vitest'
import type { CliResult } from '../../shared/transport.ts'
import { describeDefinition, valueLabel } from './definition-info.ts'
import { fakeTransport } from './fake-transport.ts'

const paths = { definitionDirs: [], skillsDir: null, recordsDir: null }

function answering(result: CliResult) {
  return fakeTransport({
    paths,
    files: {},
    cli: (binary, args) => {
      expect([binary, ...args]).toEqual(['synapse-pipeline', 'show', 'Strict', '--format', 'json'])
      return result
    },
  })
}

const system = JSON.stringify({
  format: 'synapse-pipeline-definition/v1',
  kind: 'system',
  name: 'Strict',
  file: '/d/Strict.synapse',
  attributes: [
    { name: 'Agent', value: 'Reviewer' },
    { name: 'Retries', value: 2 },
    { name: 'Outcomes', value: { Approved: 'Fine.' } },
  ],
  used_by: [
    { kind: 'pipeline', name: 'Develop', file: '/d/Develop.synapse', steps: ['Review'] },
    { kind: 'pipeline', name: 'Other', file: '/d/Other.synapse' },
  ],
})

describe('describeDefinition', () => {
  it('has the attributes as written and who uses it, with the steps of a pipeline', async () => {
    const info = await describeDefinition(
      answering({ code: 0, stdout: system, stderr: '' }),
      'Strict',
    )
    expect(info).toMatchObject({ kind: 'system', name: 'Strict', file: '/d/Strict.synapse' })
    expect(info.attributes.map((a) => a.name)).toEqual(['Agent', 'Retries', 'Outcomes'])
    expect(info.used_by).toEqual([
      { kind: 'pipeline', name: 'Develop', file: '/d/Develop.synapse', steps: ['Review'] },
      { kind: 'pipeline', name: 'Other', file: '/d/Other.synapse', steps: [] },
    ])
  })

  it('says what the CLI said when it could not describe it', async () => {
    const refused = answering({ code: 1, stdout: '', stderr: "error: there is no 'Strict'\n" })
    await expect(describeDefinition(refused, 'Strict')).rejects.toThrow("there is no 'Strict'")
  })

  it('refuses an answer that is not JSON, is another format, or describes a pipeline', async () => {
    await expect(
      describeDefinition(answering({ code: 0, stdout: 'x', stderr: '' }), 'Strict'),
    ).rejects.toThrow('did not answer JSON')
    const pipeline = JSON.stringify({ format: 'synapse-pipeline-description/v1', name: 'Strict' })
    await expect(
      describeDefinition(answering({ code: 0, stdout: pipeline, stderr: '' }), 'Strict'),
    ).rejects.toThrow('does not know')
  })
})

describe('valueLabel', () => {
  it('is a string as it is and anything else as JSON', () => {
    expect(valueLabel('Reviewer')).toBe('Reviewer')
    expect(valueLabel(2)).toBe('2')
    expect(valueLabel({ Done: 'x' })).toBe('{"Done":"x"}')
  })
})
