// The pipeline a run is drawn on. A run that is going has resolved it when it
// started, and says exactly what it is. The record of a run that is over does not
// keep it, so that run is drawn on the definition as it is now.

import type { Transport } from '../../shared/transport.ts'
import {
  describePipeline,
  parseDescription,
  type PipelineDescription,
  type Problem,
} from './pipelines.ts'

export type RunGraph =
  | {
      ok: true
      description: PipelineDescription
      // True when the run itself gave the description, so it is what ran.
      exact: boolean
    }
  | { ok: false; problems: Problem[] }

export async function describeRun(
  transport: Transport,
  executionId: string,
  pipeline: string,
): Promise<RunGraph> {
  try {
    const answer = await transport.runRequest(executionId, { command: 'pipeline' })
    const description = answer.ok ? parseDescription(answer.result) : null
    if (description !== null) return { ok: true, description, exact: true }
  } catch {
    // Nothing answers: the run is over, or it died.
  }
  const described = await describePipeline(transport, pipeline)
  return described.ok
    ? { ok: true, description: described.description, exact: false }
    : { ok: false, problems: described.problems }
}
