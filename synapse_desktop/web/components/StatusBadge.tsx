import type { ExecutionStatus } from '../domain/executions.ts'

const LABELS: Record<ExecutionStatus, string> = {
  running: 'running',
  completed: 'completed',
  failed: 'failed',
  interrupted: 'interrupted',
  incomplete: 'incomplete',
}

// The status is always written out; the color only backs it up.
export function StatusBadge({ status }: { status: ExecutionStatus }) {
  return (
    <span className="badge" data-status={status}>
      {LABELS[status]}
    </span>
  )
}
