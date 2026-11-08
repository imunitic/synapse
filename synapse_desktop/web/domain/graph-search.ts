// The local files of a code graph, as `synapse callers` and `synapse index` read
// them for a namespace: the references and definitions of a symbol, the nodes,
// the files they cover and which node owns a file. Everything here only reads.

import type { Transport } from '../../shared/transport.ts'

async function run(transport: Transport, args: string[]): Promise<string> {
  const result = await transport.cli('synapse', args)
  if (result.code !== 0) {
    throw new Error(result.stderr.trim() === '' ? `${args[0]} failed` : result.stderr.trim())
  }
  return result.stdout
}

function lines(text: string): string[] {
  return text.split('\n').filter((line) => line !== '')
}

export interface Graph {
  // `<repo>@<branch>`.
  namespace: string
  // The node index, the reference index and the tags cache this namespace has.
  hasIndex: boolean
  hasRefs: boolean
  hasTags: boolean
}

// The rows of `work-dir --list`: a namespace, a tab and what it has.
export function parseGraphs(text: string): Graph[] {
  return lines(text).map((line) => {
    const [namespace = '', has = ''] = line.split('\t')
    const parts = has.split(',')
    return {
      namespace,
      hasIndex: parts.includes('index'),
      hasRefs: parts.includes('refs'),
      hasTags: parts.includes('tags'),
    }
  })
}

// The namespaces that have local files of a graph.
export async function listGraphs(transport: Transport): Promise<Graph[]> {
  return parseGraphs(await run(transport, ['work-dir', '--list']))
}

export interface SymbolHit {
  // What the hit is: a definition, a reference or, without --all, a call.
  role: 'def' | 'ref' | 'call'
  // The kind of a definition or reference, such as `function`.
  kind: string | null
  path: string
  line: number | null
  expression: string
}

// `path:line` as a path and a line; the line is null when there is none.
export function splitPlace(place: string): { path: string; line: number | null } {
  const colon = place.lastIndexOf(':')
  const line = Number(place.slice(colon + 1))
  return colon > 0 && Number.isInteger(line) && line > 0
    ? { path: place.slice(0, colon), line }
    : { path: place, line: null }
}

// The rows of `callers`: `path:line<TAB>expression` for calls, and with --all
// `def|ref<TAB>kind<TAB>path:line<TAB>expression`.
export function parseSymbolHits(text: string, all: boolean): SymbolHit[] {
  const hits: SymbolHit[] = []
  for (const line of lines(text)) {
    const parts = line.split('\t')
    if (all) {
      const [role, kind, place, ...rest] = parts
      if ((role === 'def' || role === 'ref') && place !== undefined) {
        hits.push({ role, kind: kind ?? null, ...splitPlace(place), expression: rest.join('\t') })
      }
    } else {
      const [place, ...rest] = parts
      if (place !== undefined) {
        hits.push({ role: 'call', kind: null, ...splitPlace(place), expression: rest.join('\t') })
      }
    }
  }
  return hits
}

// The calls of an exact name, or with `all` every definition and reference.
export async function findSymbol(
  transport: Transport,
  namespace: string,
  name: string,
  all: boolean,
): Promise<SymbolHit[]> {
  const args = ['callers', name, ...(all ? ['--all'] : []), '--namespace', namespace]
  return parseSymbolHits(await run(transport, args), all)
}

// The nodes of a namespace, as the names of their notes.
export async function listNodes(transport: Transport, namespace: string): Promise<string[]> {
  return lines(await run(transport, ['index', 'nodes', '--namespace', namespace]))
}

// The path of a node's note in the vault.
export function nodeNotePath(namespace: string, node: string): string {
  return `synapse/${namespace}/${node.endsWith('.md') ? node : `${node}.md`}`
}

// Every path the nodes cover.
export async function listCoveredPaths(transport: Transport, namespace: string): Promise<string[]> {
  return lines(await run(transport, ['index', 'paths', '--namespace', namespace]))
}

// The paths no node claims.
export async function listUnassigned(transport: Transport, namespace: string): Promise<string[]> {
  return lines(await run(transport, ['index', 'unassigned', '--namespace', namespace]))
}

// The nodes that own a path.
export async function ownersOf(
  transport: Transport,
  namespace: string,
  path: string,
): Promise<string[]> {
  return lines(await run(transport, ['index', 'lookup', path, '--namespace', namespace]))
}

// The paths that hold every word of `query`, in any case, best matches first: a
// path whose file name holds the text comes before one that only has it in a
// folder.
export function filterPaths(paths: readonly string[], query: string, limit: number): string[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (words.length === 0) return []
  const name = (path: string) => path.slice(path.lastIndexOf('/') + 1).toLowerCase()
  return paths
    .filter((path) => words.every((word) => path.toLowerCase().includes(word)))
    .sort((a, b) => {
      const inName = (p: string) => (words.every((w) => name(p).includes(w)) ? 0 : 1)
      return inName(a) - inName(b) || a.length - b.length || a.localeCompare(b)
    })
    .slice(0, limit)
}
