// Describing a system or an agent: what `synapse-pipeline show <name> --format json`
// answers, with the definitions that use it.

import { z } from 'zod'
import type { Transport } from '../../shared/transport.ts'

const userSchema = z.object({
  // A pipeline uses a system or an agent; a system uses an agent.
  kind: z.enum(['pipeline', 'system', 'agent']),
  name: z.string(),
  file: z.string(),
  // The steps of a pipeline that name it; none for a system.
  steps: z.array(z.string()).default([]),
})

const infoSchema = z.object({
  format: z.literal('synapse-pipeline-definition/v1'),
  kind: z.enum(['system', 'agent']),
  name: z.string(),
  file: z.string(),
  // As they are written in the file, in order.
  attributes: z.array(z.object({ name: z.string(), value: z.unknown() })),
  used_by: z.array(userSchema),
})

export type DefinitionInfo = z.infer<typeof infoSchema>
export type DefinitionUser = DefinitionInfo['used_by'][number]

// One attribute's value for a line of text.
export function valueLabel(value: unknown): string {
  return typeof value === 'string' ? value : JSON.stringify(value)
}

// The system or agent as the CLI describes it. Throws with the CLI's own words when it
// cannot, and when the answer is in a format this app does not know.
export async function describeDefinition(
  transport: Transport,
  name: string,
): Promise<DefinitionInfo> {
  const result = await transport.cli('synapse-pipeline', ['show', name, '--format', 'json'])
  if (result.code !== 0) {
    throw new Error(
      result.stderr
        .split('\n')
        .map((line) => line.replace(/^(error|warning):\s*/, '').trim())
        .filter((line) => line !== '')
        .join(' ') || 'show failed',
    )
  }
  let json: unknown
  try {
    json = JSON.parse(result.stdout)
  } catch {
    throw new Error('show did not answer JSON')
  }
  const parsed = infoSchema.safeParse(json)
  if (!parsed.success) throw new Error('show answered a description this app does not know')
  return parsed.data
}
