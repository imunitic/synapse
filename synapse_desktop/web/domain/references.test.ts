import { describe, expect, it } from 'vitest'
import type { CliResult, Transport } from '../../shared/transport.ts'
import { fakeTransport } from './fake-transport.ts'
import { DEVELOP_FEATURE_SHOW } from './fixtures.ts'
import type { PipelineDescription } from './pipelines.ts'
import { buildReferenceIndex, referencesOf, usedBy } from './references.ts'

const develop = JSON.parse(DEVELOP_FEATURE_SHOW) as PipelineDescription

describe('referencesOf', () => {
  it('finds the systems, agents and prompts of every step of a real pipeline', () => {
    const found = referencesOf(develop).map((r) => `${r.kind} ${r.name} @ ${r.step}`)
    expect(found).toEqual([
      'agent Developer @ Develop',
      'agent Tester @ Test',
      'prompt Test_Feature @ Test',
      'system Strict_Reviewer @ Review',
      'agent Reviewer @ Review',
      'prompt Review_Code @ Review',
    ])
  })

  it('finds nothing in a pipeline built from nothing', () => {
    const bare = structuredClone(develop)
    for (const step of bare.steps) {
      step.origins = []
      step.role = null
      step.assignment = null
    }
    expect(referencesOf(bare)).toEqual([])
  })
})

describe('buildReferenceIndex', () => {
  function world(shows: Record<string, CliResult>): Transport {
    const listing = JSON.stringify({
      format: 'synapse-pipeline-definitions/v1',
      definitions: [
        { kind: 'pipeline', name: 'Develop_Feature', file: '/d/Develop_Feature.synapse' },
        { kind: 'pipeline', name: 'Broken', file: '/d/Broken.synapse' },
        { kind: 'agent', name: 'Reviewer', file: '/d/Reviewer.synapse' },
      ],
      problems: [],
    })
    return fakeTransport({
      paths: { definitionDirs: ['/d'], recordsDir: null },
      files: {},
      cli: (_binary, args) =>
        args[0] === 'definitions'
          ? { code: 0, stdout: listing, stderr: '' }
          : (shows[args[1] ?? ''] ?? { code: 1, stdout: '', stderr: 'error: nope' }),
    })
  }

  const ok: CliResult = { code: 0, stdout: DEVELOP_FEATURE_SHOW, stderr: '' }

  it('indexes the pipelines that can be described and lists the ones that cannot', async () => {
    const index = await buildReferenceIndex(
      world({ Develop_Feature: ok, Broken: { code: 1, stdout: '', stderr: 'error: bad' } }),
    )
    expect(index.pipelines.map((p) => p.name)).toEqual(['Broken', 'Develop_Feature'])
    expect(index.unreadable).toEqual(['Broken'])
    expect(usedBy(index, 'system', 'Strict_Reviewer')).toEqual([
      { kind: 'system', name: 'Strict_Reviewer', pipeline: 'Develop_Feature', step: 'Review' },
    ])
  })

  it('finds nothing for a definition no pipeline uses, and keeps kinds apart', async () => {
    const index = await buildReferenceIndex(world({ Develop_Feature: ok }))
    expect(usedBy(index, 'agent', 'Nobody')).toEqual([])
    // The prompt Review_Code is not an agent of that name.
    expect(usedBy(index, 'agent', 'Review_Code')).toEqual([])
    expect(usedBy(index, 'prompt', 'Review_Code')).toEqual([
      { kind: 'prompt', name: 'Review_Code', pipeline: 'Develop_Feature', step: 'Review' },
    ])
  })
})
