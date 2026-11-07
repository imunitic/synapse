import { describe, expect, it } from 'vitest'
import type { CliResult, Transport } from '../../shared/transport.ts'
import { fakeTransport } from './fake-transport.ts'
import { DEVELOP_FEATURE_SHOW } from './fixtures.ts'
import type { PipelineDescription } from './pipelines.ts'
import { buildReferenceIndex, referencesOf, usedBy } from './references.ts'

const develop = JSON.parse(DEVELOP_FEATURE_SHOW) as PipelineDescription

describe('referencesOf', () => {
  it('finds the systems, agents and skills of every step of a real pipeline', () => {
    const found = referencesOf(develop).map((r) => `${r.kind} ${r.name} @ ${r.step}`)
    expect(found).toEqual([
      'agent Developer @ Develop',
      'agent Tester @ Test',
      'skill test-feature @ Test',
      'system Strict_Reviewer @ Review',
      'agent Reviewer @ Review',
      'skill review-code @ Review',
    ])
  })

  it('names a skill once for a step that uses it as its role and its assignment', () => {
    const twice = structuredClone(develop)
    const review = twice.steps[2]!
    review.role = { kind: 'skill', name: 'review-code' }
    const found = referencesOf(twice).filter((r) => r.kind === 'skill' && r.step === 'Review')
    expect(found).toHaveLength(1)
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
    const base = fakeTransport({
      paths: { definitionDirs: ['/d'], skillsDir: null, recordsDir: null },
      files: {
        '/d/Develop_Feature.synapse': 'Pipeline Develop_Feature {}',
        '/d/Broken.synapse': 'Pipeline Broken {}',
        '/d/Reviewer.synapse': 'Agent Reviewer [Prompt => "x"];',
      },
    })
    return {
      ...base,
      cli: (_binary, args) =>
        Promise.resolve(shows[args[1] ?? ''] ?? { code: 1, stdout: '', stderr: 'error: nope' }),
    }
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
    // The skill review-code is not an agent of that name.
    expect(usedBy(index, 'agent', 'review-code')).toEqual([])
    expect(usedBy(index, 'skill', 'review-code')).toHaveLength(1)
  })
})
