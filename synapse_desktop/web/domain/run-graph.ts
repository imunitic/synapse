// The pipeline a run is drawn on. A run that is going has resolved it when it
// started, and says exactly what it is over its socket. The record of a run keeps
// the same document as `description.json`. A record made before that was kept
// has none, and its run is drawn on the definition as it is now.

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

// The description the run's record keeps, or null when it has none or it
// cannot be read.
async function readRecordedDescription(
  transport: Transport,
  executionId: string,
): Promise<PipelineDescription | null> {
  try {
    const { recordsDir } = await transport.getPaths()
    if (recordsDir === null) return null
    const text = await transport.readText(`${recordsDir}/${executionId}/description.json`)
    return parseDescription(JSON.parse(text))
  } catch {
    return null
  }
}

// `going` is whether the run's record says it is going: only then is its socket
// asked, so that a run that is over is not probed.
export async function describeRun(
  transport: Transport,
  executionId: string,
  pipeline: string,
  going: boolean,
): Promise<RunGraph> {
  if (going) {
    try {
      const answer = await transport.runRequest(executionId, { command: 'pipeline' })
      const description = answer.ok ? parseDescription(answer.result) : null
      if (description !== null) return { ok: true, description, exact: true }
    } catch {
      // Nothing answers: the run died.
    }
  }
  const recorded = await readRecordedDescription(transport, executionId)
  if (recorded !== null) return { ok: true, description: recorded, exact: true }
  const described = await describePipeline(transport, pipeline)
  return described.ok
    ? { ok: true, description: described.description, exact: false }
    : { ok: false, problems: described.problems }
}
