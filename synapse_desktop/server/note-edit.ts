// Having an agent change a note that is there already. The session is told which note
// and to touch no other; the app cannot confine a session to one note, since the
// synapse program writes any, so it reads the note before and after, gives the two back
// to be shown and undone, and checks that no other note moved.

import type { AppConfig, CliResult, Harness, NoteEdit } from '../shared/transport.ts'
import type { CliRunner } from './cli.ts'
import { editPrompt, failureOf, pathsOf } from './note-agent.ts'

// Why a note was not changed, with the status the caller should see.
export class EditRefused extends Error {
  status: number

  constructor(message: string, status = 409) {
    super(message)
    this.status = status
  }
}

// The nodes of a code graph, `synapse/<repo>@<branch>/<node>.md`, are written by the
// graph tools, which compute what each one holds; a change by hand puts them out of step.
const GRAPH_NODE = /^synapse\/[^/]+@[^/]+\//

// Why a path may not be changed here, or null when it may: a note of the vault by its
// path, which is relative and stays inside the vault.
export function notePathProblem(path: string): string | null {
  if (path === '' || path.length > 1024 || path.includes('\0')) return 'There is no such note.'
  if (path.startsWith('/') || /^[A-Za-z]:/.test(path) || path.split('/').includes('..')) {
    return 'A note is named by its path in the vault.'
  }
  if (!path.endsWith('.md')) return 'Only a note, a .md file, can be changed here.'
  if (GRAPH_NODE.test(path)) {
    return 'The nodes of a code graph are written by the graph tools and are not changed by hand.'
  }
  return null
}

export interface EditDeps {
  run: CliRunner
  config: AppConfig
  harness: Harness
  // Runs the session with the prompt it is given.
  session: (prompt: string) => Promise<CliResult>
}

async function readText(run: CliRunner, config: AppConfig, path: string): Promise<string> {
  const result = await run({ binary: 'synapse', args: ['vault-read', path], config })
  if (result.code !== 0) {
    throw new EditRefused(`${path} could not be read: ${result.stderr.trim()}`.trim(), 404)
  }
  return result.stdout
}

// The date each note says it was updated, by path; a note with none is not in it.
export async function stamps(run: CliRunner, config: AppConfig): Promise<Map<string, string>> {
  const result = await run({
    binary: 'synapse',
    args: ['vault-search', '--fields', 'frontmatter.updated'],
    config,
    stdin: '{"var":"frontmatter.updated"}',
  })
  const found = new Map<string, string>()
  if (result.code !== 0) return found
  for (const line of result.stdout.split('\n')) {
    const [path, updated] = line.split('\t')
    if (path !== undefined && path !== '' && updated !== undefined) found.set(path, updated)
  }
  return found
}

async function listing(run: CliRunner, config: AppConfig): Promise<Set<string>> {
  const result = await run({ binary: 'synapse', args: ['vault-list'], config })
  return new Set(result.code === 0 ? pathsOf(result.stdout) : [])
}

// The other notes that moved: one whose date changed, one that is new and one that is
// gone, in path order.
export function touchedElsewhere(
  before: { stamps: ReadonlyMap<string, string>; paths: ReadonlySet<string> },
  after: { stamps: ReadonlyMap<string, string>; paths: ReadonlySet<string> },
  target: string,
): string[] {
  const moved = new Set<string>()
  for (const [path, updated] of after.stamps) {
    if (before.stamps.get(path) !== updated) moved.add(path)
  }
  for (const path of before.stamps.keys()) if (!after.stamps.has(path)) moved.add(path)
  for (const path of after.paths) if (!before.paths.has(path)) moved.add(path)
  for (const path of before.paths) if (!after.paths.has(path)) moved.add(path)
  moved.delete(target)
  return [...moved].sort((a, b) => a.localeCompare(b))
}

export async function editNote(
  deps: EditDeps,
  path: string,
  description: string,
): Promise<NoteEdit> {
  const problem = notePathProblem(path)
  if (problem !== null) throw new EditRefused(problem, 400)
  const { run, config } = deps
  const before = await readText(run, config, path)
  const seen = { stamps: await stamps(run, config), paths: await listing(run, config) }
  const result = await deps.session(editPrompt(path, description, deps.harness))
  const after = await readText(run, config, path)
  if (after === before) {
    const why =
      failureOf(result.stdout) ?? (result.stderr.trim() || result.stdout.trim().slice(-300))
    throw new EditRefused(`The note was not changed. ${why}`.trim(), 502)
  }
  const now = { stamps: await stamps(run, config), paths: await listing(run, config) }
  return { before, after, touched: touchedElsewhere(seen, now, path) }
}

// Puts the text from before back, when the note is still as the edit left it: a note
// that was changed again since is not overwritten.
export async function restoreNote(
  run: CliRunner,
  config: AppConfig,
  path: string,
  before: string,
  after: string,
): Promise<void> {
  const problem = notePathProblem(path)
  if (problem !== null) throw new EditRefused(problem, 400)
  if ((await readText(run, config, path)) !== after) {
    throw new EditRefused('The note was changed again since, so it is not put back.')
  }
  const result = await run({
    binary: 'synapse',
    args: ['vault-write', path],
    config,
    stdin: before,
  })
  if (result.code !== 0) {
    throw new EditRefused(`The note could not be put back: ${result.stderr.trim()}`.trim(), 502)
  }
}
