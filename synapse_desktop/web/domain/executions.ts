// The runs of the work directory: each has a record directory, and a socket
// while it goes.

import { z } from 'zod'
import type { CliResult, Transport } from '../../shared/transport.ts'
import { formatStartTime } from './format.ts'

// `execution.json`, as the pipeline writes it. The state is the run's own
// document; only what the lists show is named here.
const executionSchema = z.object({
  format: z.literal('synapse-pipeline-execution/v1'),
  id: z.string(),
  pipeline: z.string(),
  started: z.string(),
  ended: z.string().nullable(),
  status: z.enum(['running', 'completed', 'failed']),
  current_step: z.string().nullable(),
  // Whether the run has a terminal; absent from records written before the field existed.
  interactive: z.boolean().optional(),
  // Whether an interactive run is waiting for a person; absent for one that is not interactive.
  attention: z
    .object({
      state: z.enum(['running', 'waiting']),
      reason: z.string().nullable().optional(),
      since: z.string(),
    })
    .optional(),
  state: z.looseObject({
    steps_run: z.number().optional(),
    // How many times each edge has been taken, by the edge's index.
    fired: z.array(z.number()).optional(),
    failure: z
      .looseObject({ message: z.string().optional(), step: z.string().optional() })
      .nullable()
      .optional(),
  }),
})

const eventSchema = z.object({
  sequence: z.number(),
  kind: z.string(),
  step: z.string().nullable(),
  detail: z.unknown(),
})

export type RunEvent = z.infer<typeof eventSchema>

// `interrupted`: the record says running and nothing answers on the socket.
// `incomplete`: there is no readable summary.
export type ExecutionStatus = 'running' | 'completed' | 'failed' | 'interrupted' | 'incomplete'

export interface ExecutionSummary {
  id: string
  // The name a person gave the run, from the record's `name` file; null when it has none.
  name: string | null
  pipeline: string | null
  status: ExecutionStatus
  started: string | null
  ended: string | null
  currentStep: string | null
  stepsRun: number | null
  failure: string | null
  failureStep: string | null
  // How many times each edge has been taken, by the edge's index.
  fired: number[]
  // An interactive run that is going on: whether it is waiting for a person, and what its agent
  // said. Null for any other run.
  attention: Attention | null
  // Whether the run was started with a terminal; null when the record does not say.
  interactive: boolean | null
}

export interface Attention {
  state: 'running' | 'waiting'
  reason: string | null
  since: string
}

function incomplete(id: string): ExecutionSummary {
  return {
    id,
    name: null,
    pipeline: null,
    status: 'incomplete',
    started: null,
    ended: null,
    currentStep: null,
    stepsRun: null,
    failure: null,
    failureStep: null,
    fired: [],
    attention: null,
    interactive: null,
  }
}

// The summary a record's text holds, with the status the record claims; null
// when it is not one.
export function parseExecution(id: string, text: string): ExecutionSummary | null {
  let json: unknown
  try {
    json = JSON.parse(text)
  } catch {
    return null
  }
  const parsed = executionSchema.safeParse(json)
  if (!parsed.success || parsed.data.id !== id) return null
  const { data } = parsed
  return {
    id,
    name: null,
    pipeline: data.pipeline,
    status: data.status,
    started: data.started,
    ended: data.ended,
    currentStep: data.current_step,
    stepsRun: data.state.steps_run ?? null,
    failure: data.state.failure?.message ?? null,
    failureStep: data.state.failure?.step ?? null,
    fired: data.state.fired ?? [],
    attention:
      data.attention === undefined
        ? null
        : {
            state: data.attention.state,
            reason: data.attention.reason ?? null,
            since: data.attention.since,
          },
    interactive: data.interactive ?? null,
  }
}

// What a run says it is waiting for, as long as it is going on: a run that has ended, or whose
// record says it is running and nothing answers, waits for nobody.
export function waitingFor(run: ExecutionSummary): string | null {
  return run.status === 'running' && run.attention?.state === 'waiting'
    ? (run.attention.reason ?? '')
    : null
}

// The events of `events.jsonl`. Each event is appended on its own, so a last
// line without its line feed may be half written and is left out, as is a
// line that is not an event.
export function parseEvents(text: string): RunEvent[] {
  const lines = text.split('\n')
  lines.pop()
  const events: RunEvent[] = []
  for (const line of lines) {
    if (line.trim() === '') continue
    try {
      const parsed = eventSchema.safeParse(JSON.parse(line))
      if (parsed.success) events.push(parsed.data)
    } catch {
      continue
    }
  }
  return events
}

// A run that is going answers on its socket; one whose record still says
// running and does not has died.
async function isListening(transport: Transport, id: string): Promise<boolean> {
  try {
    const answer = await transport.runRequest(id, { command: 'info' })
    return answer.ok
  } catch {
    return false
  }
}

export async function summarize(
  transport: Transport,
  recordsDir: string,
  id: string,
): Promise<ExecutionSummary> {
  const [text, name] = await Promise.all([
    transport.readText(`${recordsDir}/${id}/execution.json`).catch(() => null),
    readName(transport, recordsDir, id),
  ])
  const parsed = text === null ? null : parseExecution(id, text)
  const summary = parsed === null ? incomplete(id) : { ...parsed, name }
  if (summary.status !== 'running') return summary
  return { ...summary, status: (await isListening(transport, id)) ? 'running' : 'interrupted' }
}

// The run's name from its `name` file: a run with no file, or an empty one, has none.
async function readName(
  transport: Transport,
  recordsDir: string,
  id: string,
): Promise<string | null> {
  const text = await transport.readText(`${recordsDir}/${id}/name`).catch(() => null)
  const name = text?.trim() ?? ''
  return name === '' ? null : name
}

// The two lines a run is shown with in the sidebar. A named run shows its name, with the pipeline
// and start time under it; an unnamed one shows the pipeline and start time, and no second line
// of its own (its row keeps the id and step line).
export function runLabel(run: ExecutionSummary): { title: string; note: string | null } {
  const pipeline = run.pipeline ?? 'unknown pipeline'
  const started = run.started === null ? '' : formatStartTime(run.started)
  const where = started === '' ? pipeline : `${pipeline} · ${started}`
  return run.name === null ? { title: where, note: null } : { title: run.name, note: where }
}

// Names a run, or clears its name when the trimmed name is empty. Throws with what the engine
// said when it refuses.
export async function setRunName(transport: Transport, id: string, name: string): Promise<void> {
  const trimmed = name.trim()
  const result = await transport.cli('synapse-pipeline', [
    'name',
    id,
    ...(trimmed === '' ? [] : [trimmed]),
  ])
  if (result.code !== 0) {
    throw new Error((result.stderr || result.stdout).trim() || `${id} could not be named`)
  }
}

// What `cleanup --format json` answers: the runs removed (or that would be, in a dry run), and
// the ones kept with the reason.
const cleanupSchema = z.object({
  format: z.literal('synapse-pipeline-cleanup/v1'),
  dry_run: z.boolean(),
  removed: z.array(z.string()),
  kept: z.array(z.object({ id: z.string(), reason: z.string() })),
})

export interface CleanupResult {
  removed: string[]
  kept: { id: string; reason: string }[]
}

// What the app asks before it deletes one run, from its row or from its page.
export const DELETE_ONE_CONFIRM =
  'Delete the record of this run? Its transcripts, patches and outcomes are removed. The changes it made in the repository stay.'

const KEPT_REASONS: Record<string, string> = {
  running: 'running',
  not_found: 'not found',
  cannot_remove: 'cannot be removed',
}

// Why the engine kept a run it was asked to remove, in words. A reason this app does not know is
// shown as the engine wrote it.
export function keptReasonText(reason: string): string {
  return KEPT_REASONS[reason] ?? reason
}

export type CleanupChoice = { kind: 'olderThan'; days: number } | { kind: 'all' }

// Both hosts take at most 32 arguments in a `cli` call: `cleanup`, `--format`, `json` and 29
// more, so the ids go 30 at a time to stay clear of it.
const CLEANUP_BATCH = 30

// The cleanup document in the answer. Cleanup exits 1 when it kept a run it was asked to remove,
// and still answers the document, so the code does not decide; an answer that is not the
// document is an error with what the engine said.
function readCleanup(result: CliResult): CleanupResult {
  let json: unknown
  try {
    json = JSON.parse(result.stdout)
  } catch {
    throw new Error(result.stderr.trim() || 'cleanup did not answer JSON')
  }
  const parsed = cleanupSchema.safeParse(json)
  if (!parsed.success) {
    throw new Error(result.stderr.trim() || 'cleanup answered a format this app does not know')
  }
  return { removed: parsed.data.removed, kept: parsed.data.kept }
}

// Removes the records of the given runs. A running run, or one that is not there, is kept and
// reported in `kept`.
export async function removeExecutions(
  transport: Transport,
  ids: string[],
): Promise<CleanupResult> {
  const merged: CleanupResult = { removed: [], kept: [] }
  for (let at = 0; at < ids.length; at += CLEANUP_BATCH) {
    const batch = ids.slice(at, at + CLEANUP_BATCH)
    const result = readCleanup(
      await transport.cli('synapse-pipeline', ['cleanup', '--format', 'json', ...batch]),
    )
    merged.removed.push(...result.removed)
    merged.kept.push(...result.kept)
  }
  return merged
}

function cleanupArgs(choice: CleanupChoice): string[] {
  return choice.kind === 'all' ? ['--all'] : ['--older-than', `${choice.days}d`]
}

// What a cleanup would remove, without removing anything.
export async function planCleanup(
  transport: Transport,
  choice: CleanupChoice,
): Promise<CleanupResult> {
  return readCleanup(
    await transport.cli('synapse-pipeline', [
      'cleanup',
      ...cleanupArgs(choice),
      '--dry-run',
      '--format',
      'json',
    ]),
  )
}

// Removes the records of the finished runs the choice takes in.
export async function runCleanup(
  transport: Transport,
  choice: CleanupChoice,
): Promise<CleanupResult> {
  return readCleanup(
    await transport.cli('synapse-pipeline', [
      'cleanup',
      ...cleanupArgs(choice),
      '--format',
      'json',
    ]),
  )
}

// One run's summary, from its record, with the status it really has.
export async function readSummary(transport: Transport, id: string): Promise<ExecutionSummary> {
  const { recordsDir } = await transport.getPaths()
  if (recordsDir === null) return incomplete(id)
  return summarize(transport, recordsDir, id)
}

// Every run, newest first; one with no readable summary goes last.
export async function listExecutions(transport: Transport): Promise<ExecutionSummary[]> {
  const { recordsDir } = await transport.getPaths()
  if (recordsDir === null) return []
  const entries = await transport.readDir(recordsDir)
  const summaries = await Promise.all(
    entries.filter((e) => e.isDir).map((e) => summarize(transport, recordsDir, e.name)),
  )
  return summaries.sort((a, b) => (b.started ?? '').localeCompare(a.started ?? ''))
}

export interface ExecutionRecord {
  summary: ExecutionSummary
  events: RunEvent[]
}

// One run's summary and its events, from its record.
export async function readExecution(transport: Transport, id: string): Promise<ExecutionRecord> {
  const { recordsDir } = await transport.getPaths()
  if (recordsDir === null) throw new Error('there is no work directory')
  const [summary, events] = await Promise.all([
    summarize(transport, recordsDir, id),
    transport
      .readText(`${recordsDir}/${id}/events.jsonl`)
      .then(parseEvents)
      .catch(() => []),
  ])
  return { summary, events }
}
