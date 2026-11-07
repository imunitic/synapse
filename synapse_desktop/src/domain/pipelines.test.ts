import { describe, expect, it } from 'vitest'
import type { CliResult, Transport } from '../../shared/transport.ts'
import { fakeTransport } from './fake-transport.ts'
import { BROKEN_ONE_STDERR, DEVELOP_FEATURE_SHOW } from './fixtures.ts'
import { describePipeline, guardLabel, parseProblems } from './pipelines.ts'

function withCli(result: CliResult): Transport {
  const base = fakeTransport({
    files: {},
    paths: { definitionDirs: [], skillsDir: null, recordsDir: null },
  })
  return { ...base, cli: () => Promise.resolve(result) }
}

describe('describePipeline', () => {
  it('reads what show answers for a real pipeline', async () => {
    const described = await describePipeline(
      withCli({ code: 0, stdout: DEVELOP_FEATURE_SHOW, stderr: '' }),
      'Develop_Feature',
    )
    expect(described.ok).toBe(true)
    if (!described.ok) return
    const { description } = described
    expect(description.steps.map((s) => s.name)).toEqual(['Develop', 'Test', 'Review'])
    expect(description.steps[2]).toMatchObject({
      harness: 'Codex',
      permissions: 'Read_Only',
      assignment: { kind: 'skill', name: 'review-code' },
    })
    expect(description.steps[2]?.origins.map((o) => [o.kind, o.name])).toEqual([
      ['system', 'Strict_Reviewer'],
      ['agent', 'Reviewer'],
    ])
    expect(description.edges[0]).toMatchObject({ from: 'Review', to: 'Develop', max_iterations: 5 })
  })

  it('returns the problems of a pipeline that cannot run', async () => {
    const described = await describePipeline(
      withCli({ code: 1, stdout: '', stderr: BROKEN_ONE_STDERR }),
      'Broken_One',
    )
    expect(described.ok).toBe(false)
    if (described.ok) return
    expect(described.problems).toHaveLength(3)
    expect(described.problems[0]).toEqual({
      severity: 'error',
      file: '/defs/Broken_One.synapse',
      line: 1,
      column: 32,
      message: "unknown attribute 'Harnes'",
    })
  })

  it('reports a failure that printed nothing', async () => {
    const described = await describePipeline(withCli({ code: 1, stdout: '', stderr: '' }), 'X')
    expect(described).toMatchObject({ ok: false, problems: [{ message: 'show failed' }] })
  })

  it('throws when show answers something that is not a description', async () => {
    await expect(
      describePipeline(withCli({ code: 0, stdout: 'nope', stderr: '' }), 'X'),
    ).rejects.toThrow(/JSON/)
    await expect(
      describePipeline(withCli({ code: 0, stdout: '{"format":"other/v9"}', stderr: '' }), 'X'),
    ).rejects.toThrow(/does not know/)
  })
})

describe('parseProblems', () => {
  it('reads a Windows path that holds a colon', () => {
    expect(parseProblems('error: C:\\defs\\P.synapse:3:9: bad thing')[0]).toMatchObject({
      file: 'C:\\defs\\P.synapse',
      line: 3,
      column: 9,
      message: 'bad thing',
    })
  })

  it('reads warnings and keeps a line of another shape whole', () => {
    expect(parseProblems('warning: /d/A.synapse:1:1: odd\nsomething else\n\n')).toEqual([
      { severity: 'warning', file: '/d/A.synapse', line: 1, column: 1, message: 'odd' },
      { severity: 'error', file: null, line: null, column: null, message: 'something else' },
    ])
  })
})

describe('guardLabel', () => {
  it('shortens an outcome test to the outcome', () => {
    expect(guardLabel({ '==': [{ var: 'outcome' }, 'Changes_Requested'] })).toBe(
      'Changes_Requested',
    )
  })

  it('writes any other rule as JSON and no guard as null', () => {
    expect(guardLabel({ '>': [{ var: 'x' }, 1] })).toBe('{">":[{"var":"x"},1]}')
    expect(guardLabel(null)).toBeNull()
  })
})
