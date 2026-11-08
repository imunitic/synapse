// What a dry run of deleting a graph, or of cleaning up the graphs of branches
// that are gone, says, put into words for the question asked before it is done.

export interface DropSummary {
  nodes: number
  // How many of the nodes have text in their `## Notes`, which a person wrote.
  withNotes: number
}

// The line `namespace: synapse/<ns> (N nodes, M with ## Notes content)`.
export function parseDropSummary(lines: readonly string[]): DropSummary | null {
  for (const line of lines) {
    const match = /\((\d+) nodes?, (\d+) with ## Notes content\)/.exec(line)
    if (match !== null) return { nodes: Number(match[1]), withNotes: Number(match[2]) }
  }
  return null
}

// What a drop would remove: the paths the dry run names.
export function removals(lines: readonly string[]): string[] {
  return lines
    .filter((l) => l.startsWith('would-remove '))
    .map((l) => l.slice('would-remove '.length))
}

// Whether a dry run found nothing to do.
export function nothingToClean(lines: readonly string[]): boolean {
  return removals(lines).length === 0
}

// The question asked before a graph is deleted.
export function dropQuestion(namespace: string, lines: readonly string[]): string {
  const summary = parseDropSummary(lines)
  const size =
    summary === null
      ? ''
      : ` Its ${summary.nodes} ${summary.nodes === 1 ? 'node' : 'nodes'} will be removed from the vault${
          summary.withNotes > 0
            ? `, ${summary.withNotes} of them with Notes written by hand, which are kept for a rebuild`
            : ''
        }.`
  return `This deletes the graph of ${namespace}.${size}`
}
