// The runs of the work directory: each has a record directory, and a socket
// while it goes.

import { z } from 'zod'
import type { Transport } from '../../shared/transport.ts'

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
}

function incomplete(id: string): ExecutionSummary {
  return {
    id,
    pipeline: null,
    status: 'incomplete',
    started: null,
    ended: null,
    currentStep: null,
    stepsRun: null,
    failure: null,
    failureStep: null,
    fired: [],
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
    pipeline: data.pipeline,
    status: data.status,
    started: data.started,
    ended: data.ended,
    currentStep: data.current_step,
    stepsRun: data.state.steps_run ?? null,
    failure: data.state.failure?.message ?? null,
    failureStep: data.state.failure?.step ?? null,
    fired: data.state.fired ?? [],
  }
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

async function summarize(
  transport: Transport,
  recordsDir: string,
  id: string,
): Promise<ExecutionSummary> {
  const text = await transport.readText(`${recordsDir}/${id}/execution.json`).catch(() => null)
  const summary = text === null ? null : parseExecution(id, text)
  if (summary === null) return incomplete(id)
  if (summary.status !== 'running') return summary
  return { ...summary, status: (await isListening(transport, id)) ? 'running' : 'interrupted' }
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
