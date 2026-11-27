// The fields a step's result holds in `data`: what its `Data` declares, and what the outcome it
// ended with declares on top.

import type { InputField, PipelineDescription } from './pipelines.ts'

// The step's `Data` fields, then the outcome's `data` fields. Empty for a step the description
// does not have, or one that declares neither.
export function dataFieldsFor(
  description: PipelineDescription,
  step: string,
  outcome: string,
): InputField[] {
  const declared = description.steps.find((s) => s.name === step)
  if (declared === undefined) return []
  const outcomeFields = declared.outcomes?.find((o) => o.word === outcome)?.data ?? []
  return [...(declared.data?.fields ?? []), ...outcomeFields]
}
