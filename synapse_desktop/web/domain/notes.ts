// The notes of the vault, as `synapse vault-list`, `vault-read`, `vault-search-text`,
// `vault-links` and `vault-backlinks` give them: the folder tree, a note with its
// frontmatter and body, and the links between notes. Everything here only reads.

import { parse as parseYaml } from 'yaml'
import type { Transport } from '../../shared/transport.ts'

async function vault(transport: Transport, args: string[]): Promise<string> {
  const result = await transport.cli('synapse', args)
  if (result.code !== 0) {
    throw new Error(result.stderr.trim() === '' ? `${args[0]} failed` : result.stderr.trim())
  }
  return result.stdout
}

function lines(text: string): string[] {
  return text.split('\n').filter((line) => line !== '')
}

// The path of every note, as the vault gives them.
export async function listNotes(transport: Transport): Promise<string[]> {
  return lines(await vault(transport, ['vault-list']))
}

// A note's name: the file's name without `.md`, which is how a wikilink names it.
export function titleOf(path: string): string {
  const name = path.slice(path.lastIndexOf('/') + 1)
  return name.endsWith('.md') ? name.slice(0, -3) : name
}

export interface TreeNote {
  name: string
  path: string
}

export interface TreeFolder {
  name: string
  path: string
  folders: TreeFolder[]
  notes: TreeNote[]
}

// The paths as folders of folders and notes, each sorted by name with the
// folders first. The index and the readme of a folder come before its other notes.
export function buildTree(paths: readonly string[]): TreeFolder {
  const root: TreeFolder = { name: '', path: '', folders: [], notes: [] }
  for (const path of paths) {
    const parts = path.split('/')
    let folder = root
    for (const [i, part] of parts.slice(0, -1).entries()) {
      const at = parts.slice(0, i + 1).join('/')
      let next = folder.folders.find((f) => f.path === at)
      if (next === undefined) {
        next = { name: part, path: at, folders: [], notes: [] }
        folder.folders.push(next)
      }
      folder = next
    }
    folder.notes.push({ name: titleOf(path), path })
  }
  const order = (a: string, b: string) => {
    const front = (n: string) => (n === 'Index' || n === 'README' ? 0 : 1)
    return front(a) - front(b) || a.localeCompare(b)
  }
  const sort = (folder: TreeFolder) => {
    folder.folders.sort((a, b) => a.name.localeCompare(b.name))
    folder.notes.sort((a, b) => order(a.name, b.name))
    folder.folders.forEach(sort)
  }
  sort(root)
  return root
}

export interface SearchHit {
  path: string
  score: number
}

// The rows of `vault-search-text`: path, score and the lines that matched.
export function parseHits(text: string): SearchHit[] {
  return lines(text).flatMap((line) => {
    const [path, score] = line.split('\t')
    const value = Number(score)
    return path === undefined || path === '' || Number.isNaN(value) ? [] : [{ path, score: value }]
  })
}

// The notes that match the words, best first.
export async function searchNotes(transport: Transport, query: string): Promise<SearchHit[]> {
  const hits = parseHits(await vault(transport, ['vault-search-text', query]))
  return hits.sort((a, b) => b.score - a.score)
}

export interface Note {
  path: string
  title: string
  // The frontmatter as it parses, or null when there is none or it does not parse.
  frontmatter: Record<string, unknown> | null
  body: string
}

// A note's text split into its frontmatter and its body.
export function parseNote(path: string, raw: string): Note {
  const fallback = { path, title: titleOf(path), frontmatter: null, body: raw }
  const match = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(raw)
  if (match === null) return fallback
  let data: unknown
  try {
    data = parseYaml(match[1] ?? '')
  } catch {
    return fallback
  }
  if (typeof data !== 'object' || data === null || Array.isArray(data)) return fallback
  const frontmatter = data as Record<string, unknown>
  const title = typeof frontmatter.title === 'string' ? frontmatter.title : titleOf(path)
  return { path, title, frontmatter, body: raw.slice(match[0].length) }
}

export async function readNote(transport: Transport, path: string): Promise<Note> {
  return parseNote(path, await vault(transport, ['vault-read', path]))
}

// The notes a note links to, as paths.
export async function noteLinks(transport: Transport, path: string): Promise<string[]> {
  return lines(await vault(transport, ['vault-links', path]))
}

export interface Backlink {
  path: string
  count: number
}

// The notes that link to a note, and how many times each does.
export async function noteBacklinks(transport: Transport, path: string): Promise<Backlink[]> {
  return lines(await vault(transport, ['vault-backlinks', path])).flatMap((line) => {
    const [from, count] = line.split('\t')
    return from === undefined ? [] : [{ path: from, count: Number(count) || 1 }]
  })
}

// Note names to the paths that have them, since two folders can hold the same name.
export function nameIndex(paths: readonly string[]): Map<string, string[]> {
  const index = new Map<string, string[]>()
  for (const path of paths) {
    const name = titleOf(path)
    index.set(name, [...(index.get(name) ?? []), path])
  }
  return index
}

// The path a wikilink target names: the one the note itself links to when there
// are several of that name, else the first.
export function resolveLink(
  index: ReadonlyMap<string, string[]>,
  target: string,
  linked: ReadonlySet<string>,
): string | null {
  const name = target.endsWith('.md') ? target.slice(0, -3) : target
  const candidates = index.get(name) ?? index.get(name.slice(name.lastIndexOf('/') + 1)) ?? []
  return candidates.find((path) => linked.has(path)) ?? candidates[0] ?? null
}

// The scheme a rewritten wikilink gets, which the page turns into a note.
export const WIKILINK = 'wikilink:'

// `[[Target#Heading|Alias]]` as a Markdown link to `wikilink:Target`, left alone
// inside code, so that the page can send it to the note.
export function linkifyWikilinks(body: string): string {
  const link = (text: string) =>
    text.replace(/\[\[([^\]|#\n]+)(?:#[^\]|\n]*)?(?:\|([^\]\n]+))?\]\]/g, (_all, target, alias) => {
      const label = (alias ?? target).trim()
      return `[${label}](${WIKILINK}${encodeURIComponent(String(target).trim())})`
    })
  // Fenced blocks and inline code are kept as they are.
  return body
    .split(/(```[\s\S]*?```|~~~[\s\S]*?~~~)/g)
    .map((part, i) =>
      i % 2 === 1
        ? part
        : part
            .split(/(`[^`\n]*`)/g)
            .map((piece, j) => (j % 2 === 1 ? piece : link(piece)))
            .join(''),
    )
    .join('')
}

// The target a rewritten wikilink names.
export function wikilinkTarget(href: string): string | null {
  return href.startsWith(WIKILINK) ? decodeURIComponent(href.slice(WIKILINK.length)) : null
}

// The body without a first line that is a heading of level one saying what the
// page's title already says, which most notes begin with.
export function withoutTitleHeading(body: string, titles: readonly string[]): string {
  const match = /^\s*#[ \t]+(.+?)[ \t]*#*[ \t]*(?:\r?\n|$)/.exec(body)
  if (match === null || !titles.includes((match[1] ?? '').trim())) return body
  return body.slice(match[0].length).replace(/^\s*\n/, '')
}

export interface UpdatedNote {
  path: string
  title: string
  updated: string
}

// The rows of a search that asked for the title and the date a note was updated,
// newest first; a note with no date that reads as one is left out.
export function parseUpdated(text: string, limit: number): UpdatedNote[] {
  return lines(text)
    .flatMap((line) => {
      const [path, title, updated] = line.split('\t')
      if (path === undefined || updated === undefined || Number.isNaN(Date.parse(updated)))
        return []
      return [{ path, title: title === undefined || title === '' ? titleOf(path) : title, updated }]
    })
    .sort((a, b) => Date.parse(b.updated) - Date.parse(a.updated))
    .slice(0, limit)
}

// The notes that were updated last, by the date in their frontmatter.
export async function recentlyUpdated(transport: Transport, limit: number): Promise<UpdatedNote[]> {
  const result = await transport.cli(
    'synapse',
    ['vault-search', '--fields', 'frontmatter.title,frontmatter.updated'],
    {
      stdin: '{"var":"frontmatter.updated"}',
    },
  )
  if (result.code !== 0) {
    throw new Error(result.stderr.trim() === '' ? 'vault-search failed' : result.stderr.trim())
  }
  return parseUpdated(result.stdout, limit)
}

// The nodes of a code graph, `synapse/<repo>@<branch>/<node>.md`, are written by the
// graph tools, which compute what each holds, and are not changed by hand.
export function isGraphNodePath(path: string): boolean {
  return /^synapse\/[^/]+@[^/]+\//.test(path)
}
