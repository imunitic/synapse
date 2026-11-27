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

function world(shows: Record<string, CliResult>) {
  return fakeTransport({
    paths: { definitionDirs: ['/d'], recordsDir: null },
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

  it('has the steps, systems and agents a prompt is used by, as the CLI says', async () => {
    const shown = JSON.stringify({
      format: 'synapse-pipeline-definition/v1',
      kind: 'prompt',
      name: 'Review_Code',
      file: '/d/Review_Code.synapse',
      attributes: [{ name: 'Prompt', value: 'Review it.' }],
      used_by: [
        { kind: 'agent', name: 'Reviewer', file: '/d/Reviewer.synapse' },
        { kind: 'pipeline', name: 'Develop', file: '/d/Develop.synapse', steps: ['Review'] },
        { kind: 'system', name: 'Strict', file: '/d/Strict.synapse' },
      ],
    })
    expect(await definitionUse(world({ Review_Code: ok(shown) }), 'prompt', 'Review_Code')).toEqual(
      {
        users: [
          { kind: 'agent', name: 'Reviewer', steps: [] },
          { kind: 'pipeline', name: 'Develop', steps: ['Review'] },
          { kind: 'system', name: 'Strict', steps: [] },
        ],
        unchecked: [],
      },
    )
  })
})
