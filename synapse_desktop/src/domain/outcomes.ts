// How a step's result routes the run: the outcomes its edges listen for.

import { outcomeOf, type PipelineDescription } from './pipelines.ts'

export interface Route {
  edgeIndex: number
  to: string
  // The outcome the edge waits for; null when its guard is another rule, or none.
  outcome: string | null
  // The rule, as compact JSON, when it is not a test of the outcome.
  rule: string | null
  maxIterations: number | null
}

// The edges that leave a step, in the order they are tried.
export function routesFrom(description: PipelineDescription, step: string): Route[] {
  return description.edges
    .filter((edge) => edge.from === step)
    .map((edge) => {
      const outcome = outcomeOf(edge.guard)
      const hasGuard = edge.guard !== null && edge.guard !== undefined
      return {
        edgeIndex: edge.index,
        to: edge.to,
        outcome,
        rule: hasGuard && outcome === null ? JSON.stringify(edge.guard) : null,
        maxIterations: edge.max_iterations,
      }
    })
}

// What happens when no edge is taken: the next declared step, or the end of the
// run after the last.
export function fallThrough(description: PipelineDescription, step: string): string | null {
  const index = description.steps.findIndex((s) => s.name === step)
  return description.steps[index + 1]?.name ?? null
}
