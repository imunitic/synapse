import { describe, expect, it } from 'vitest'
import type { CliResult } from '../../shared/transport.ts'
import { definitionUse } from './definition-use.ts'
import { fakeTransport } from './fake-transport.ts'

const listing = JSON.stringify({
  format: 'synapse-pipeline-definitions/v1',
  definitions: [
    { kind: 'pipeline', name: 'Develop', file: '/d/Develop.synapse' },
    { kind: 'agent', name: 'Reviewer', file: '/d/Reviewer.synapse' },
    { kind: 'agent', name: 'Plain', file: '/d/Plain.synapse' },
    { kind: 'agent', name: 'Broken', file: '/d/Broken.synapse' },
    { kind: 'system', name: 'Strict', file: '/d/Strict.synapse' },
  ],
  problems: [],
})

function pipelineShowing(skill: string | null) {
  return JSON.stringify({
    format: 'synapse-pipeline-description/v1',
    name: 'Develop',
    steps: [
      {
        name: 'Review',
        harness: 'Claude',
        model: null,
        permissions: 'Read_Only',
        timeout_seconds: 60,
        retries: 0,
        outcomes: null,
        role: null,
        assignment: skill === null ? null : { kind: 'skill', name: skill },
        origins: [],
      },
    ],
    edges: [],
    limits: { default_timeout_seconds: 60, step_ceiling: 10, runner: 'x' },
  })
}

function agentShowing(name: string, skill: string | null, kind = 'agent') {
  return JSON.stringify({
    format: 'synapse-pipeline-definition/v1',
    kind,
    name,
    file: `/d/${name}.synapse`,
    attributes: skill === null ? [] : [{ name: 'Skill', value: skill }],
    used_by: [],
  })
}

function world(shows: Record<string, CliResult>) {
  return fakeTransport({
    paths: { definitionDirs: ['/d'], skillsDir: null, recordsDir: null },
    files: {},
    cli: (_binary, args) =>
      args[0] === 'definitions'
        ? { code: 0, stdout: listing, stderr: '' }
        : (shows[args[1] ?? ''] ?? { code: 1, stdout: '', stderr: 'error: nope' }),
  })
}

const ok = (stdout: string): CliResult => ({ code: 0, stdout, stderr: '' })

describe('definitionUse', () => {
  it('finds nothing that uses a pipeline, without asking', async () => {
    expect(await definitionUse(world({}), 'pipeline', 'Develop')).toEqual({
      users: [],
      unchecked: [],
    })
  })

  it('has the pipelines and systems a system or an agent is used by, as the CLI says', async () => {
    const shown = JSON.stringify({
      format: 'synapse-pipeline-definition/v1',
      kind: 'agent',
      name: 'Reviewer',
      file: '/d/Reviewer.synapse',
      attributes: [],
      used_by: [
        { kind: 'system', name: 'Strict', file: '/d/Strict.synapse' },
        { kind: 'pipeline', name: 'Develop', file: '/d/Develop.synapse', steps: ['Review'] },
      ],
    })
    expect(await definitionUse(world({ Reviewer: ok(shown) }), 'agent', 'Reviewer')).toEqual({
      users: [
        { kind: 'system', name: 'Strict', steps: [] },
        { kind: 'pipeline', name: 'Develop', steps: ['Review'] },
      ],
      unchecked: [],
    })
  })

  it('says a skill is used by the steps that name it and the agents and systems that carry it', async () => {
    const use = await definitionUse(
      world({
        Develop: ok(pipelineShowing('review-code')),
        Reviewer: ok(agentShowing('Reviewer', 'review-code')),
        Plain: ok(agentShowing('Plain', null)),
        Broken: { code: 1, stdout: '', stderr: 'error: broken' },
        Strict: ok(agentShowing('Strict', 'review-code', 'system')),
      }),
      'skill',
      'review-code',
    )
    expect(use.users).toEqual([
      { kind: 'pipeline', name: 'Develop', steps: ['Review'] },
      { kind: 'agent', name: 'Reviewer', steps: [] },
      { kind: 'system', name: 'Strict', steps: [] },
    ])
    // An agent that cannot be read might carry the skill: it is not passed over.
    expect(use.unchecked).toEqual(['Broken'])
  })

  it('finds a skill that nothing names unused', async () => {
    const use = await definitionUse(
      world({
        Develop: ok(pipelineShowing('another')),
        Reviewer: ok(agentShowing('Reviewer', 'another')),
        Plain: ok(agentShowing('Plain', null)),
        Broken: ok(agentShowing('Broken', null)),
        Strict: ok(agentShowing('Strict', null, 'system')),
      }),
      'skill',
      'review-code',
    )
    expect(use).toEqual({ users: [], unchecked: [] })
  })
})
