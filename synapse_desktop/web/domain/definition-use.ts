// What still uses a definition, which decides whether it may be deleted: a system or an agent is
// used by the pipelines and systems that name it, a skill by the steps, systems and agents that name it, and
// nothing uses a pipeline.

import type { Transport } from '../../shared/transport.ts'
import { describeDefinition, valueLabel } from './definition-info.ts'
import { loadDefinitions } from './definitions.ts'
import { buildReferenceIndex, usedBy } from './references.ts'

export type DefinitionOrSkill = 'pipeline' | 'system' | 'agent' | 'skill'

export interface DefinitionUser {
  kind: 'pipeline' | 'system' | 'agent'
  name: string
  // The steps of a pipeline that use it; none for a system or an agent.
  steps: string[]
}

export interface DefinitionUse {
  users: DefinitionUser[]
  // Definitions that could not be read, so that nothing can be said of whether they use it.
  unchecked: string[]
}

async function carriersOfSkill(transport: Transport, skill: string): Promise<DefinitionUse> {
  const { definitions } = await loadDefinitions(transport)
  const users: DefinitionUser[] = []
  const unchecked: string[] = []
  const described = await Promise.all(
    definitions
      .filter((d) => d.kind === 'agent' || d.kind === 'system')
      .map(async (d) => ({
        d,
        info: await describeDefinition(transport, d.name).catch(() => null),
      })),
  )
  for (const { d, info } of described) {
    if (info === null) unchecked.push(d.name)
    else if (info.attributes.some((a) => a.name === 'Skill' && valueLabel(a.value) === skill)) {
      users.push({ kind: d.kind as 'system' | 'agent', name: d.name, steps: [] })
    }
  }
  return { users, unchecked }
}

// Who uses the definition. Throws when the CLI cannot be asked.
export async function definitionUse(
  transport: Transport,
  kind: DefinitionOrSkill,
  name: string,
): Promise<DefinitionUse> {
  if (kind === 'pipeline') return { users: [], unchecked: [] }
  if (kind === 'skill') {
    const [index, carriers] = await Promise.all([
      buildReferenceIndex(transport),
      carriersOfSkill(transport, name),
    ])
    const byPipeline = new Map<string, string[]>()
    for (const reference of usedBy(index, 'skill', name)) {
      byPipeline.set(reference.pipeline, [
        ...(byPipeline.get(reference.pipeline) ?? []),
        reference.step,
      ])
    }
    return {
      users: [
        ...[...byPipeline].map(([pipeline, steps]) => ({
          kind: 'pipeline' as const,
          name: pipeline,
          steps,
        })),
        ...carriers.users,
      ],
      unchecked: [...index.unreadable, ...carriers.unchecked],
    }
  }
  const info = await describeDefinition(transport, name)
  return {
    users: info.used_by.map((u) => ({ kind: u.kind, name: u.name, steps: u.steps })),
    unchecked: [],
  }
}
