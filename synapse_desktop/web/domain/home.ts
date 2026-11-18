// What the home page's cards say, worked out from what the pages already know.

import type { VaultCategory } from './attention.ts'
import { RUN_AGE_DAYS } from './attention.ts'
import type { ExecutionSummary } from './executions.ts'

export interface RunCounts {
  running: number
  completed: number
  failed: number
  interrupted: number
}

// How the runs that began in the last week ended, or are going.
export function runCounts(runs: readonly ExecutionSummary[], now: Date): RunCounts {
  const counts: RunCounts = { running: 0, completed: 0, failed: 0, interrupted: 0 }
  for (const run of runs) {
    if (run.started === null) continue
    const started = Date.parse(run.started)
    if (Number.isNaN(started) || now.getTime() - started > RUN_AGE_DAYS * 86_400_000) continue
    if (run.status in counts) counts[run.status as keyof RunCounts] += 1
  }
  return counts
}

// The newest runs that have a record of when they began.
export function recentRuns(runs: readonly ExecutionSummary[], count: number): ExecutionSummary[] {
  return runs.filter((run) => run.started !== null).slice(0, count)
}

// The vault's categories as counts by name.
export function vaultCounts(categories: readonly VaultCategory[]): Record<string, number> {
  return Object.fromEntries(categories.map((category) => [category.key, category.items.length]))
}
