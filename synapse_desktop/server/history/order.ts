import type { Workspace } from '../../shared/transport.ts'

// The most recently used first; those with no time keep the order they came in, after.
export function newestFirst(found: readonly Workspace[]): Workspace[] {
  const dated = found.filter((w) => w.lastUsed !== null)
  const undated = found.filter((w) => w.lastUsed === null)
  dated.sort((a, b) => ((a.lastUsed ?? '') < (b.lastUsed ?? '') ? 1 : -1))
  return [...dated, ...undated]
}

export const MAX_WORKSPACES = 50
