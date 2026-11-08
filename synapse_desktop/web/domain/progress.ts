// How far a run has got through its pipeline, from its events and its state:
// which steps it has been in, which edges it has taken and where it is now.

import { z } from 'zod'
import type { ExecutionSummary, RunEvent } from './executions.ts'
import type { PipelineDescription } from './pipelines.ts'

export type StepState = 'idle' | 'current' | 'interrupted' | 'done' | 'failed'

export interface StepProgress {
  state: StepState
  // How many times the run has been in the step.
  visits: number
  // The outcome of the last visit that ended.
  outcome: string | null
}

export interface Progress {
  steps: Record<string, StepProgress>
  // How many times each edge was taken, by the edge's index.
  arcCounts: Record<number, number>
  // How many times control passed from a step to the next declared one with no
  // edge taken, by the position of the step it left.
  flowCounts: number[]
  // The run ended at End, or after the last step.
  endReached: boolean
  // Steps the events name that the pipeline does not have: the definition has
  // changed since the run.
  unknownSteps: string[]
}

const finishedSchema = z.object({ outcome: z.string(), next: z.string() })

type Summary = Pick<ExecutionSummary, 'status' | 'currentStep' | 'failureStep' | 'fired'>

export function progressOf(
  description: PipelineDescription,
  events: readonly RunEvent[],
  summary: Summary,
): Progress {
  const names = description.steps.map((s) => s.name)
  const steps: Record<string, StepProgress> = Object.fromEntries(
    names.map((name) => [name, { state: 'idle', visits: 0, outcome: null }]),
  )
  const unknown = new Set<string>()
  // How many times control went from one step to another, by `from>to`.
  const passed = new Map<string, number>()
  let endByEdge = false

  for (const event of events) {
    if (event.step === null) continue
    const step = steps[event.step]
    if (step === undefined) {
      unknown.add(event.step)
      continue
    }
    if (event.kind === 'step.started') step.visits += 1
    if (event.kind === 'step.finished') {
      const finished = finishedSchema.safeParse(event.detail)
      if (!finished.success) continue
      step.outcome = finished.data.outcome
      const key = `${event.step}>${finished.data.next}`
      passed.set(key, (passed.get(key) ?? 0) + 1)
      if (finished.data.next === 'End') endByEdge = true
    }
  }

  const arcCounts: Record<number, number> = {}
  for (const edge of description.edges) arcCounts[edge.index] = summary.fired[edge.index] ?? 0

  // Control passes to the next declared step either by an edge that leads
  // there or by falling through; the transitions that no edge counts are the latter.
  const flowCounts = names.map((name, i) => {
    const next = names[i + 1]
    if (next === undefined) return 0
    const byEdges = description.edges
      .filter((e) => e.from === name && e.to === next)
      .reduce((sum, e) => sum + (arcCounts[e.index] ?? 0), 0)
    return Math.max(0, (passed.get(`${name}>${next}`) ?? 0) - byEdges)
  })

  const here = summary.currentStep
  const live = summary.status === 'running' || summary.status === 'interrupted'
  for (const [name, step] of Object.entries(steps)) {
    if (summary.status === 'failed' && summary.failureStep === name) step.state = 'failed'
    else if (live && here === name)
      step.state = summary.status === 'running' ? 'current' : 'interrupted'
    else if (step.visits > 0) step.state = 'done'
  }

  const last = names[names.length - 1]
  const fellOff =
    summary.status === 'completed' &&
    last !== undefined &&
    (steps[last]?.visits ?? 0) > 0 &&
    !endByEdge
  const lastIndex = names.length - 1
  if (fellOff && lastIndex >= 0) flowCounts[lastIndex] = 1

  return {
    steps,
    arcCounts,
    flowCounts,
    endReached: endByEdge || fellOff,
    unknownSteps: [...unknown],
  }
}

export interface Visit {
  n: number
  step: string
  // Null while the visit is going on.
  outcome: string | null
  next: string | null
}

// The steps the run has been in, in order, with how each ended.
export function visitsOf(events: readonly RunEvent[]): Visit[] {
  const visits: Visit[] = []
  for (const event of events) {
    if (event.step === null) continue
    if (event.kind === 'step.started') {
      visits.push({ n: visits.length + 1, step: event.step, outcome: null, next: null })
    } else if (event.kind === 'step.finished') {
      const finished = finishedSchema.safeParse(event.detail)
      const open = visits.findLast((v) => v.step === event.step && v.outcome === null)
      if (finished.success && open !== undefined) {
        open.outcome = finished.data.outcome
        open.next = finished.data.next === '' ? null : finished.data.next
      }
    }
  }
  return visits
}
