// What each step visit reported, as the run kept it: the record's
// `outputs/{visit}-{Step}-{attempt}.json`, named for the try the run routed on.

import { z } from 'zod'
import type { Transport } from '../../shared/transport.ts'
import type { RecordedSession } from './activity.ts'
import type { Visit } from './progress.ts'

export interface VisitOutput {
  outcome: string
  summary: string
  data: Record<string, unknown>
}

// `not-recorded`: there is no file, it cannot be read, or it is not a result.
export type VisitOutputRead =
  { status: 'recorded'; output: VisitOutput } | { status: 'not-recorded' }

export interface Problem {
  file: string | null
  location: string | null
  issue: string | null
}

const outputSchema = z.object({
  outcome: z.string(),
  summary: z.string(),
  data: z.record(z.string(), z.unknown()),
})

const NOT_RECORDED: VisitOutputRead = { status: 'not-recorded' }

// The output file of a visit, from the attempt of its last recorded session;
// null for a visit with no recorded session.
export function outputPath(
  recordsDir: string,
  id: string,
  visit: Visit,
  sessions: readonly RecordedSession[],
): string | null {
  const last = sessions.at(-1)
  if (last === undefined) return null
  return `${recordsDir}/${id}/outputs/${visit.n}-${visit.step}-${last.attempt}.json`
}

function parseOutput(text: string): VisitOutputRead {
  let json: unknown
  try {
    json = JSON.parse(text)
  } catch {
    return NOT_RECORDED
  }
  const parsed = outputSchema.safeParse(json)
  return parsed.success ? { status: 'recorded', output: parsed.data } : NOT_RECORDED
}

// The output a visit left, given the sessions recorded for that visit.
export async function readVisitOutput(
  transport: Transport,
  id: string,
  visit: Visit,
  sessions: readonly RecordedSession[],
): Promise<VisitOutputRead> {
  if (sessions.length === 0) return NOT_RECORDED
  const { recordsDir } = await transport.getPaths()
  if (recordsDir === null) return NOT_RECORDED
  const path = outputPath(recordsDir, id, visit, sessions)
  if (path === null) return NOT_RECORDED
  const text = await transport.readText(path).catch(() => null)
  return text === null ? NOT_RECORDED : parseOutput(text)
}

function text(value: unknown): string | null {
  if (typeof value === 'string') return value
  if (typeof value === 'number') return String(value)
  return null
}

// The problems a step listed in `data.problems`; entries that are not objects
// are left out.
export function problemsOf(data: Record<string, unknown>): Problem[] {
  const problems = data.problems
  if (!Array.isArray(problems)) return []
  return problems
    .filter(
      (p): p is Record<string, unknown> => typeof p === 'object' && p !== null && !Array.isArray(p),
    )
    .map((p) => ({
      file: typeof p.file === 'string' ? p.file : null,
      location: text(p.location),
      issue: typeof p.issue === 'string' ? p.issue : null,
    }))
}

// An object or array with more entries than this starts folded in the JSON tree.
const MOST_OPEN_ENTRIES = 20

// Whether a node of the JSON tree starts open: the root and its children do,
// unless they have more than MOST_OPEN_ENTRIES entries; deeper nodes start folded.
export function startsOpen(depth: number, size: number): boolean {
  return depth <= 1 && size <= MOST_OPEN_ENTRIES
}
