// The headings of a note, as `synapse vault-doc-map` gives them: one
// `heading<TAB>{H1}::{H2}::...` line per heading, in document order. Only this
// output names a heading's path; the markdown itself is never parsed for it.

import type { Transport } from '../../shared/transport.ts'

export interface OutlineHeading {
  path: string
  title: string
  depth: number
}

export interface OutlineNode {
  heading: OutlineHeading
  children: OutlineNode[]
}

const SEPARATOR = '::'

// The `heading` lines of the doc-map, in order; `block` and `frontmatter` lines are left out.
export function parseDocMap(stdout: string): OutlineHeading[] {
  const headings: OutlineHeading[] = []
  for (const line of stdout.split('\n')) {
    const tab = line.indexOf('\t')
    if (tab === -1 || line.slice(0, tab) !== 'heading') continue
    const path = line.slice(tab + 1).replace(/\r$/, '')
    if (path === '') continue
    const segments = path.split(SEPARATOR)
    headings.push({ path, title: segments.at(-1) ?? path, depth: segments.length })
  }
  return headings
}

export async function noteOutline(transport: Transport, path: string): Promise<OutlineHeading[]> {
  const args = ['vault-doc-map', path]
  const result = await transport.cli('synapse', args)
  if (result.code !== 0) {
    throw new Error(result.stderr.trim() === '' ? `${args[0]} failed` : result.stderr.trim())
  }
  return parseDocMap(result.stdout)
}

// The headings nested by path: a heading goes under the nearest earlier heading
// whose path is a prefix of its own, or at the top when there is none.
export function outlineTree(headings: readonly OutlineHeading[]): OutlineNode[] {
  const roots: OutlineNode[] = []
  const byPath = new Map<string, OutlineNode>()
  for (const heading of headings) {
    const node: OutlineNode = { heading, children: [] }
    const segments = heading.path.split(SEPARATOR)
    let parent: OutlineNode | undefined
    for (let n = segments.length - 1; n > 0 && parent === undefined; n--) {
      parent = byPath.get(segments.slice(0, n).join(SEPARATOR))
    }
    if (parent === undefined) roots.push(node)
    else parent.children.push(node)
    byPath.set(heading.path, node)
  }
  return roots
}
