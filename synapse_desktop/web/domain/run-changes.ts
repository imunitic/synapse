// What the steps of a run changed in the folder they worked in, as the run's record keeps it and
// `synapse-pipeline changes --format json` prints it: one patch for each session that changed
// something, and the snapshots the run pinned when it started and when it ended.

import { z } from 'zod'
import type { Transport } from '../../shared/transport.ts'
import { changeSet, type ChangeSet } from './changes.ts'

const changesSchema = z.object({
  format: z.literal('synapse-pipeline-changes/v1'),
  execution_id: z.string(),
  // The folder the steps worked in, when the run was told it.
  directory: z.string().nullable(),
  // Missing from an engine older than the pinned snapshots.
  status: z.string().optional(),
  snapshots: z.object({ start: z.string().nullable(), end: z.string().nullable() }).optional(),
  steps: z.array(
    z.object({
      step: z.string(),
      visit: z.number().int(),
      attempt: z.number().int(),
      patch: z.string(),
    }),
  ),
})

export interface RecordedChange {
  step: string
  // The step the run was at, from 1: a step it comes back to has a new one each time.
  visit: number
  // Which try of the step, from 1.
  attempt: number
  set: ChangeSet
}

export interface RunChanges {
  directory: string | null
  // What the run's summary says it is: running, completed, failed, or incomplete when it has none.
  status: string
  // The trees pinned in the folder the run works in when it started and when it ended; null when it
  // has not pinned one.
  snapshots: { start: string | null; end: string | null }
  // In the order the steps ran.
  changes: RecordedChange[]
}

// What the CLI said when it could not, in a line.
function reasonOf(stderr: string, stdout: string): string {
  return (
    (stderr || stdout)
      .split('\n')
      .map((line) => line.replace(/^(error|warning):\s*/, '').trim())
      .find((line) => line !== '') ?? 'the changes could not be read'
  )
}

// The changes of a run. Throws with the CLI's own words when it cannot say, and when it answers in a
// format this app does not know. With a step, the attempt of that step that is running is included,
// as the folder is now against what it was when the attempt started.
export async function readRunChanges(
  transport: Transport,
  executionId: string,
  step?: string,
): Promise<RunChanges> {
  const result = await transport.cli('synapse-pipeline', [
    'changes',
    executionId,
    ...(step === undefined ? [] : ['--step', step]),
    '--format',
    'json',
  ])
  if (result.code !== 0) throw new Error(reasonOf(result.stderr, result.stdout))
  let json: unknown
  try {
    json = JSON.parse(result.stdout)
  } catch {
    throw new Error('changes did not answer JSON')
  }
  const parsed = changesSchema.safeParse(json)
  if (!parsed.success) throw new Error('changes answered a format this app does not know')
  return {
    directory: parsed.data.directory,
    status: parsed.data.status ?? 'incomplete',
    snapshots: parsed.data.snapshots ?? { start: null, end: null },
    // A patch with no files in it has nothing to show.
    changes: parsed.data.steps
      .map((s) => ({
        step: s.step,
        visit: s.visit,
        attempt: s.attempt,
        set: changeSet(s.patch, []),
      }))
      .filter((c) => c.set.files.length > 0),
  }
}
