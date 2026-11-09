// Moving tabs and closing them: where a tab dragged over another one lands, and what a close
// has to ask about first. Pure, so that the tab bar only has to show it.

import type { ExecutionSummary } from './executions.ts'
import type { Page, TerminalSession } from '../state/state.ts'

// The place between tabs a drop is at, counted from the left: before the tab hovered over when
// the pointer is in its left half, after it when it is in the right half.
export function insertionPoint(hovered: number, pointerFraction: number): number {
  return pointerFraction < 0.5 ? hovered : hovered + 1
}

// Where a tab ends up in the list when it is taken out of `from` and put at an insertion point
// of the list as it was.
export function indexAfterMove(from: number, insertion: number): number {
  return insertion > from ? insertion - 1 : insertion
}

// The first index a tab may be moved to: the Home tab is pinned first, so nothing goes before it.
export function firstMovableIndex(tabIds: readonly string[]): number {
  return tabIds[0] === 'home' ? 1 : 0
}

export function clampIndex(index: number, tabIds: readonly string[]): number {
  return Math.min(Math.max(index, firstMovableIndex(tabIds)), tabIds.length - 1)
}

// What closing a tab would cut short, in a sentence, or null when it would cut nothing short: the
// page of the terminals ends the sessions whose program is still running, and the page of a
// run that is going on is shown without the run being stopped.
export function closeWarning(
  page: Page,
  terminals: readonly TerminalSession[],
  runs: readonly ExecutionSummary[],
): string | null {
  if (page.kind === 'terminals') {
    const running = terminals.filter((t) => t.ended !== true).length
    if (running === 0) return null
    return running === 1
      ? 'One session is still running, and closing the tab ends it.'
      : `${running} sessions are still running, and closing the tab ends them.`
  }
  if (page.kind === 'execution') {
    const run = runs.find((r) => r.id === page.id)
    return run?.status === 'running'
      ? 'This run is still going. Closing the tab does not stop it.'
      : null
  }
  return null
}
