// What the home page's cards say, worked out from what the pages already know.

import type { AppConfig, Integration } from '../../shared/transport.ts'
import type { VaultAttention, VaultCategory } from './attention.ts'
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

export interface SetupStep {
  key: string
  label: string
  done: boolean
  target: { kind: 'settings'; section: 'general' | 'vault' | 'integrations' }
}

export type SetupSource<T> =
  { status: 'loading' } | { status: 'ready'; data: T } | { status: 'failed'; error: string }

// What the app needs to be useful: a place for the records of runs, a vault and
// Synapse in a harness. A step whose answer is not known yet is not listed, so
// that a step never shows as undone only because the page is still loading.
export function setupSteps(sources: {
  config: SetupSource<AppConfig>
  vault: SetupSource<VaultAttention>
  integrations: SetupSource<Integration[]>
}): SetupStep[] {
  const steps: SetupStep[] = []
  if (sources.config.status === 'ready') {
    steps.push({
      key: 'work-dir',
      label: 'Set a work directory for the records of runs',
      done: sources.config.data.workDir !== null,
      target: { kind: 'settings', section: 'general' },
    })
  }
  if (sources.vault.status === 'ready') {
    steps.push({
      key: 'vault',
      label: 'Choose a vault',
      done: sources.vault.data.configured,
      target: { kind: 'settings', section: 'vault' },
    })
  }
  if (sources.integrations.status === 'ready') {
    steps.push({
      key: 'harness',
      label: 'Install Synapse in a harness',
      done: sources.integrations.data.some((item) =>
        ['current', 'different', 'newer', 'installed'].includes(item.state),
      ),
      target: { kind: 'settings', section: 'integrations' },
    })
  }
  return steps
}

// The vault's categories as counts by name.
export function vaultCounts(categories: readonly VaultCategory[]): Record<string, number> {
  return Object.fromEntries(categories.map((category) => [category.key, category.items.length]))
}
