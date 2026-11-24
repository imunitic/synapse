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

// The paths more than one heading has: `vault-doc-map` gives sibling headings with the same title
// the same path, so such a path cannot say which of them a comment is about, and the app offers
// no comment on it. Scrolling to it goes to the first.
export function duplicatePaths(headings: readonly OutlineHeading[]): Set<string> {
  const seen = new Set<string>()
  const duplicates = new Set<string>()
  for (const { path } of headings) {
    if (seen.has(path)) duplicates.add(path)
    seen.add(path)
  }
  return duplicates
}

// Where the private-use stand-ins for escaped characters start (see `visibleTitle`).
const ESCAPE_BASE = 0xe000

// A doc-map title as the page shows it: `vault-doc-map` keeps a heading's inline markdown, so code
// spans, emphasis, links, wikilinks, HTML tags, backslash escapes and closing hashes are reduced
// to their visible text. Escaped characters are swapped for private-use stand-ins before any rule
// runs, so an escaped `*`, `_`, `~` or bracket is never read as markup, and swapped back at the end.

export function visibleTitle(title: string): string {
  const inline = (text: string) =>
    text
      .replace(/\\([!-/:-@[-`{-~])/g, (_all, char: string) =>
        String.fromCharCode(ESCAPE_BASE + char.charCodeAt(0)),
      )
      .replace(/\[\[([^\]|#\n]+)(?:#[^\]|\n]*)?(?:\|([^\]\n]+))?\]\]/g, (_all, target, alias) =>
        String(alias ?? target).trim(),
      )
      .replace(/!?\[([^\]\n]*)\]\([^)\n]*\)/g, '$1')
      .replace(/<\/?[A-Za-z][^>\n]*>/g, '')
      .replace(/(\*\*|__|~~)(\S(?:.*?\S)?)\1/g, '$2')
      .replace(/(^|[^\w*])([*_])(\S(?:.*?\S)?)\2(?![\w*])/g, '$1$3')
      .replace(/[\ue000-\ue07f]/g, (char) => String.fromCharCode(char.charCodeAt(0) - ESCAPE_BASE))
  return title
    .replace(/\s+#+\s*$/, '')
    .split(/(`+)([^`]*?)\1/g)
    .map((piece, i) => (i % 3 === 0 ? inline(piece) : i % 3 === 2 ? piece : ''))
    .join('')
    .trim()
}

// What two titles are compared by: the text without any emphasis or code marks left over, and
// with runs of white space as one space. The rendered side is already visible text, so only the
// doc-map side goes through `visibleTitle` first; reducing the rendered text as markdown would
// change what a code span shows (`Vec<String>`, `[x](y)`) on one side only.
function comparable(text: string): string {
  return text
    .replace(/[*_~`]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

// Pairs the headings rendered in the note body, in document order, with the
// doc-map headings by title in order: for each rendered title the next doc-map
// heading with that title is its path (titles compared by their visible text, see `visibleTitle`), and the doc-map headings passed over on
// the way (the H1 the page strips, a heading inside a code block) stay unpaired.
// A rendered title with no later doc-map heading of that title gets null.
export function pairHeadings(
  outline: readonly OutlineHeading[],
  rendered: readonly string[],
): (string | null)[] {
  let next = 0
  return rendered.map((text) => {
    const title = comparable(text)
    for (let n = next; n < outline.length; n++) {
      const heading = outline[n]
      if (heading !== undefined && comparable(visibleTitle(heading.title)) === title) {
        next = n + 1
        return heading.path
      }
    }
    return null
  })
}
