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

// A check's findings by node: each node once, in the order its first finding came, with its
// reasons. A node that is named for many reasons is one row to open, not many rows. The
// repository is a node here too, called `(repo)`, so that its findings stay together.
export interface NodeFindings {
  node: string
  reasons: string[]
}

export function groupFindings(findings: readonly GraphFinding[]): NodeFindings[] {
  const groups = new Map<string, string[]>()
  for (const { node, reason } of findings) {
    const reasons = groups.get(node)
    if (reasons === undefined) groups.set(node, [reason])
    else if (!reasons.includes(reason)) reasons.push(reason)
  }
  return [...groups].map(([node, reasons]) => ({ node, reasons }))
}

// A node's reasons with those of the same kind made one: `grounding changed: a b` and
// `grounding changed: c d e` are one reason, `grounding changed`, for the files a b c d e, so that
// the same words are not read many times over. A reason that lists no files is kept once.
export function mergeReasons(reasons: readonly string[]): Reason[] {
  const kinds = new Map<string, string[]>()
  for (const reason of reasons) {
    const at = reason.indexOf(': ')
    const kind = at < 0 ? reason : reason.slice(0, at)
    const files =
      at < 0
        ? []
        : reason
            .slice(at + 2)
            .split(/\s+/)
            .filter(Boolean)
    const known = kinds.get(kind)
    if (known === undefined) kinds.set(kind, [...new Set(files)])
    else for (const file of files) if (!known.includes(file)) known.push(file)
  }
  return [...kinds].map(([kind, files]) => {
    if (files.length === 0) return { text: kind, items: [] }
    if (files.length <= MOST_IN_A_LINE) return { text: `${kind}: ${files.join(' ')}`, items: [] }
    return { text: `${kind} (${files.length})`, items: files }
  })
}
