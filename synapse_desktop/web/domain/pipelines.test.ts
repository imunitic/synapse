import { describe, expect, it } from 'vitest'
import type { CliResult, Transport } from '../../shared/transport.ts'
import { fakeTransport } from './fake-transport.ts'
import { BROKEN_ONE_STDERR, DEVELOP_FEATURE_SHOW } from './fixtures.ts'
import {
  describePipeline,
  describeStepPrompt,
  splitPrompt,
  guardLabel,
  parseDescription,
  parseProblems,
} from './pipelines.ts'

function withCli(result: CliResult): Transport {
  const base = fakeTransport({
    files: {},
    paths: { definitionDirs: [], recordsDir: null },
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
      assignment: { kind: 'prompt', text: 'Review the change and say what is wrong with it.' },
    })
    expect(description.steps[2]?.origins.map((o) => [o.kind, o.name])).toEqual([
      ['system', 'Strict_Reviewer'],
      ['agent', 'Reviewer'],
      ['prompt', 'Review_Code'],
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

describe('the outcomes of a step', () => {
  const withOutcomes = () => {
    const description = JSON.parse(DEVELOP_FEATURE_SHOW) as {
      steps: Record<string, unknown>[]
    }
    description.steps[2]!.outcomes = [
      { word: 'Approved', meaning: 'Every requirement is met.' },
      { word: 'Changes_Requested', meaning: 'Something is unmet.' },
    ]
    return description
  }

  it('are the words and meanings a step declares, in order', () => {
    const parsed = parseDescription(withOutcomes())
    expect(parsed?.steps[2]?.outcomes).toEqual([
      { word: 'Approved', meaning: 'Every requirement is met.' },
      { word: 'Changes_Requested', meaning: 'Something is unmet.' },
    ])
  })

  it('are null for a step that declares none, whether the CLI says null or says nothing', () => {
    const parsed = parseDescription(JSON.parse(DEVELOP_FEATURE_SHOW))
    expect(parsed?.steps[0]?.outcomes).toBeNull()
    const explicit = withOutcomes()
    explicit.steps[0]!.outcomes = null
    expect(parseDescription(explicit)?.steps[0]?.outcomes).toBeNull()
  })
})

describe('the input a pipeline declares', () => {
  it('a description with input parses', () => {
    const description = JSON.parse(DEVELOP_FEATURE_SHOW) as Record<string, unknown>
    description.input = {
      fields: [
        {
          name: 'task_id',
          type: 'string',
          required: true,
          description: 'The task.',
          pattern: '^[a-z]+-[0-9]+$',
        },
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
      checks: [{ '!=': [{ var: 'task_id' }, 'x-1'] }],
      single_text_field: 'task_id',
    }
    const parsed = parseDescription(description)
    expect(parsed?.input?.single_text_field).toBe('task_id')
    expect(parsed?.input?.fields[0]).toMatchObject({ name: 'task_id', pattern: '^[a-z]+-[0-9]+$' })
    expect(parsed?.input?.fields[1]?.items).toEqual({
      fields: [{ name: 'path', type: 'string', required: true, description: 'A path.' }],
    })
    expect(parsed?.input?.checks).toHaveLength(1)
  })

  it('a description without input parses with null', () => {
    expect(parseDescription(JSON.parse(DEVELOP_FEATURE_SHOW))?.input).toBeNull()
    const explicit = JSON.parse(DEVELOP_FEATURE_SHOW) as Record<string, unknown>
    explicit.input = null
    expect(parseDescription(explicit)?.input).toBeNull()
  })
})

describe('describeStepPrompt', () => {
  const prompt = JSON.stringify({
    format: 'synapse-pipeline-prompt/v1',
    pipeline: 'P',
    step: 'A',
    prompt: 'You review.\n\nDo it.',
    parts: [
      { kind: 'role', authored: true, text: 'You review.' },
      { kind: 'assignment', authored: true, text: 'Do it.' },
      { kind: 'contract', authored: false, text: 'Reply with JSON.' },
    ],
  })

  function recording(result: CliResult) {
    const calls: { args: readonly string[]; stdin: string | undefined }[] = []
    const transport = fakeTransport({
      files: {},
      paths: { definitionDirs: [], recordsDir: null },
      cli: (_binary, args, options) => {
        calls.push({ args, stdin: options?.stdin })
        return result
      },
    })
    return { calls, transport }
  }

  it('asks for the step by name and has the prompt the CLI built', async () => {
    const { calls, transport } = recording({ code: 0, stdout: prompt, stderr: '' })
    expect(await describeStepPrompt(transport, 'P', 'A')).toEqual({
      ok: true,
      prompt: 'You review.\n\nDo it.',
      parts: [
        { kind: 'role', authored: true, text: 'You review.' },
        { kind: 'assignment', authored: true, text: 'Do it.' },
        { kind: 'contract', authored: false, text: 'Reply with JSON.' },
      ],
    })
    expect(calls).toEqual([
      { args: ['show', 'P', '--step', 'A', '--format', 'json'], stdin: undefined },
    ])
  })

  it('tells what the author wrote from what the program adds', () => {
    expect(
      splitPrompt([
        { kind: 'role', authored: true, text: 'You review.' },
        { kind: 'assignment', authored: true, text: 'Do it.' },
        { kind: 'protocol', authored: false, text: 'You are running as the step A.' },
        { kind: 'contract', authored: false, text: 'Reply with JSON.' },
      ]),
    ).toEqual({
      authored: 'You review.\n\nDo it.',
      added: 'You are running as the step A.\n\nReply with JSON.',
    })
    expect(splitPrompt([])).toEqual({ authored: '', added: '' })
  })

  it('hands an input to the CLI on standard input', async () => {
    const { calls, transport } = recording({ code: 0, stdout: prompt, stderr: '' })
    await describeStepPrompt(transport, 'P', 'A', '{"n": 1}')
    expect(calls[0]?.args).toEqual(['show', 'P', '--step', 'A', '--format', 'json', '--input', '-'])
    expect(calls[0]?.stdin).toBe('{"n": 1}')
  })

  it('asks for the prompt of an interactive run when it is one', async () => {
    const { calls, transport } = recording({ code: 0, stdout: prompt, stderr: '' })
    await describeStepPrompt(transport, 'P', 'A', undefined, true)
    expect(calls[0]?.args).toEqual([
      'show',
      'P',
      '--step',
      'A',
      '--format',
      'json',
      '--interactive',
    ])
  })

  it('says why when the CLI cannot, such as for an input that is not JSON', async () => {
    const { transport } = recording({
      code: 1,
      stdout: '',
      stderr: 'error: --input - is not JSON: UNEXPECTED_CHARACTER at byte 1\n',
    })
    expect(await describeStepPrompt(transport, 'P', 'A', 'x')).toEqual({
      ok: false,
      message: '--input - is not JSON: UNEXPECTED_CHARACTER at byte 1',
    })
  })

  it('throws for an answer that is not a prompt of a format it knows', async () => {
    await expect(
      describeStepPrompt(recording({ code: 0, stdout: 'x', stderr: '' }).transport, 'P', 'A'),
    ).rejects.toThrow('did not answer JSON')
    await expect(
      describeStepPrompt(
        recording({ code: 0, stdout: '{"format":"x"}', stderr: '' }).transport,
        'P',
        'A',
      ),
    ).rejects.toThrow('does not know')
  })
})
