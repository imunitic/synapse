// What still uses a definition, which decides whether it may be deleted: a system, an agent or a
// prompt is used by the definitions that name it, as `show` says, and nothing uses a pipeline.

import type { Transport } from '../../shared/transport.ts'
import { describeDefinition } from './definition-info.ts'
import type { DefinitionKind } from './definitions.ts'

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

// Who uses the definition. Throws when the CLI cannot be asked.
export async function definitionUse(
  transport: Transport,
  kind: DefinitionKind,
  name: string,
): Promise<DefinitionUse> {
  if (kind === 'pipeline') return { users: [], unchecked: [] }
  const info = await describeDefinition(transport, name)
  return {
    users: info.used_by.map((u) => ({ kind: u.kind, name: u.name, steps: u.steps })),
    unchecked: [],
  }
}
