// Cloning a pipeline: the name a copy is offered, the copy's text, and what is wrong
// with a name the person types for it.

import { definitionNameSchema } from '../../shared/calls.ts'
import type { DefinitionKind } from './definitions.ts'

export function cloneName(name: string): string {
  return `${name}_Copy`
}

function escaped(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

// The pipeline's text with its name changed in two places only: the first header line
// `Pipeline <Old> {`, and a leading `-- <Old>.synapse` comment when the text's first
// non-empty line is one. A step or agent named like the pipeline keeps its name.
export function clonePipelineText(text: string, oldName: string, newName: string): string {
  const name = escaped(oldName)
  const lines = text.split('\n')
  const first = lines.findIndex((line) => line.trim() !== '')
  const comment = new RegExp(`^(\\s*--\\s*)${name}(\\.synapse\\s*)$`)
  const firstLine = lines[first]
  if (firstLine !== undefined && comment.test(firstLine)) {
    lines[first] = firstLine.replace(comment, `$1${newName}$2`)
  }
  const header = new RegExp(`^(\\s*Pipeline\\s+)${name}(\\s*\\{)`)
  const at = lines.findIndex((line) => header.test(line))
  const headerLine = lines[at]
  if (headerLine !== undefined) lines[at] = headerLine.replace(header, `$1${newName}$2`)
  return lines.join('\n')
}

// Why a name cannot be the copy's, or null when it can.
export function cloneNameProblem(
  name: string,
  existing: readonly { name: string; kind: DefinitionKind }[],
): string | null {
  if (!definitionNameSchema.safeParse(name).success) {
    return 'A name has letters, digits and underscores, starts with a letter and is at most 128 characters.'
  }
  const taken = existing.find((definition) => definition.name === name)
  const article = taken?.kind === 'agent' ? 'An' : 'A'
  return taken === undefined ? null : `${article} ${taken.kind} called ${name} already exists.`
}
