// What a graph's health checks add up to, for the pages that show them.

import type { GraphCheck, GraphFinding, GraphHealth } from '../../shared/transport.ts'

// The findings of a check, none when it could not run.
export function findingsOf(check: GraphCheck): GraphFinding[] {
  return check.ok ? check.findings : []
}

// The nodes named by any check, each once; the repository itself is not a node.
export function nodesNeedingAttention(health: GraphHealth): string[] {
  const nodes = new Set<string>()
  for (const check of [health.stale, health.drift, health.grounding]) {
    for (const finding of findingsOf(check)) {
      if (finding.node !== '(repo)') nodes.add(finding.node)
    }
  }
  return [...nodes].sort((a, b) => a.localeCompare(b))
}

// How many nodes are stale: the number that a person wants to see first.
export function staleCount(health: GraphHealth): number {
  return new Set(findingsOf(health.stale).map((f) => f.node)).size
}

// Whether any check could not run, which is not the same as all being well.
export function anyCheckFailed(health: GraphHealth): boolean {
  return [health.stale, health.drift, health.grounding].some((check) => !check.ok)
}

// A line about a graph's health, or null when it is clean.
export function healthLine(namespace: string, health: GraphHealth): string | null {
  const stale = staleCount(health)
  const attention = nodesNeedingAttention(health).length
  if (anyCheckFailed(health)) return `${namespace}: a check could not run`
  if (stale > 0) return `${namespace}: ${stale} ${stale === 1 ? 'node is' : 'nodes are'} stale`
  if (attention > 0) {
    return `${namespace}: ${attention} ${attention === 1 ? 'node needs' : 'nodes need'} a look`
  }
  return null
}

// A finding's reason, with the files it lists moved out of the sentence: a node
// can have dozens of source files gone, which are a list to open, not a line to read.
export interface Reason {
  text: string
  items: string[]
}

const MOST_IN_A_LINE = 3

// `source files gone: a b c d` is the text `source files gone (4)` and the files
// a, b, c and d; a reason that names few files is kept as it is.
export function splitReason(reason: string): Reason {
  const at = reason.indexOf(': ')
  if (at < 0) return { text: reason, items: [] }
  const items = reason
    .slice(at + 2)
    .split(/\s+/)
    .filter(Boolean)
  if (items.length <= MOST_IN_A_LINE) return { text: reason, items: [] }
  return { text: `${reason.slice(0, at)} (${items.length})`, items }
}
