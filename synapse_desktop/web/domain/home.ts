// What the home page's cards say, worked out from what the pages already know.

import type { VaultCategory } from './attention.ts'
import { RUN_AGE_DAYS } from './attention.ts'
import type { ExecutionSummary } from './executions.ts'
import { terminalName, type Page, type TerminalSession } from '../state/state.ts'

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

// A line of the "Running now" card for a session that is open.
export type SessionRow =
  // A shell or harness terminal, which is selected on the terminals page.
  | { kind: 'terminal'; id: string; label: string }
  // A pipeline's session, which is shown on the page of its run.
  | { kind: 'run'; id: string; label: string; page: Page }

// The open sessions as lines of the card. A pipeline's session is not on the terminals page: it
// is on the page of its run, or on the starting page until the run has an id. A run that the card
// already lists as running is not listed a second time.
export function sessionRows(
  sessions: readonly TerminalSession[],
  running: readonly ExecutionSummary[],
): SessionRow[] {
  return sessions.flatMap((session): SessionRow[] => {
    const label = terminalName(session)
    if (session.kind !== 'Pipeline') return [{ kind: 'terminal', id: session.id, label }]
    const id = session.executionId
    if (id === undefined) {
      return [
        { kind: 'run', id: session.id, label, page: { kind: 'run-starting', session: session.id } },
      ]
    }
    if (running.some((run) => run.id === id)) return []
    return [{ kind: 'run', id: session.id, label, page: { kind: 'execution', id } }]
  })
}
