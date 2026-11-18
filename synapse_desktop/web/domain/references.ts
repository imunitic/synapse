// Which pipelines use a system, an agent or a skill, from what each pipeline
// says about itself.

import type { Transport } from '../../shared/transport.ts'
import { listDefinitions, type Definition } from './definitions.ts'
import { describePipeline, type PipelineDescription } from './pipelines.ts'

export type ReferencedKind = 'system' | 'agent' | 'skill'

export interface Reference {
  kind: ReferencedKind
  name: string
  pipeline: string
  step: string
}

// What the steps of a pipeline are built from: the systems and agents in their
// origins, and the skills they name as their role or their assignment.
export function referencesOf(description: PipelineDescription): Reference[] {
  const found: Reference[] = []
  for (const step of description.steps) {
    for (const origin of step.origins) {
      found.push({
        kind: origin.kind,
        name: origin.name,
        pipeline: description.name,
        step: step.name,
      })
    }
    for (const instruction of [step.role, step.assignment]) {
      if (instruction?.kind === 'skill') {
        found.push({
          kind: 'skill',
          name: instruction.name,
          pipeline: description.name,
          step: step.name,
        })
      }
    }
  }
  // A skill may be both the role and the assignment of one step.
  const seen = new Set<string>()
  return found.filter((r) => {
    const key = `${r.kind}:${r.name}:${r.pipeline}:${r.step}`
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

export interface ReferenceIndex {
  references: Reference[]
  // The pipelines, to open the ones that are named.
  pipelines: Definition[]
  // Pipelines that could not be described, and so are not in the index.
  unreadable: string[]
}

export async function buildReferenceIndex(transport: Transport): Promise<ReferenceIndex> {
  const pipelines = (await listDefinitions(transport)).filter((d) => d.kind === 'pipeline')
  const references: Reference[] = []
  const unreadable: string[] = []
  const described = await Promise.all(
    pipelines.map(async (p) => ({
      p,
      result: await describePipeline(transport, p.name).catch(() => null),
    })),
  )
  for (const { p, result } of described) {
    if (result?.ok) references.push(...referencesOf(result.description))
    else unreadable.push(p.name)
  }
  return { references, pipelines, unreadable }
}

// The steps that use the definition, by pipeline and step.
export function usedBy(index: ReferenceIndex, kind: ReferencedKind, name: string): Reference[] {
  return index.references
    .filter((r) => r.kind === kind && r.name === name)
    .sort((a, b) => a.pipeline.localeCompare(b.pipeline) || a.step.localeCompare(b.step))
}
