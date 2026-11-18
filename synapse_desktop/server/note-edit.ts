// Having an agent change a note that is there already. The session is told which note
// and to touch no other; the app cannot confine a session to one note, since the
// synapse program writes any, so it reads the note before and after, gives the two back
// to be shown and undone, and checks that no other note moved.

import type { AppConfig, CliResult, Harness, NoteEdit } from '../shared/transport.ts'
import type { CliRunner } from './cli.ts'
import { editPrompt, pathsOf, reasonOf } from './note-agent.ts'
import { HostError } from '../shared/dispatch.ts'
import type { NoteStatus } from '../shared/messages.ts'
import type { ErrorCode } from '../shared/protocol.ts'

// Why a note was not changed, with the status the caller should see.
export class EditRefused extends HostError {
  constructor(message: string, code: ErrorCode = 'conflict') {
    super(code, message)
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
    throw new EditRefused(`${path} could not be read: ${result.stderr.trim()}`.trim(), 'not_found')
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
  if (problem !== null) throw new EditRefused(problem, 'bad_request')
  const { run, config } = deps
  const before = await readText(run, config, path)
  const seen = { stamps: await stamps(run, config), paths: await listing(run, config) }
  const result = await deps.session(editPrompt(path, description, deps.harness))
  const after = await readText(run, config, path)
  if (after === before) {
    const why = reasonOf(result.stdout, result.stderr)
    throw new EditRefused(`The note was not changed. ${why}`.trim(), 'unavailable')
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
  // Where the program finds the schemas it checks a note against, when the program cannot tell.
  contentRoot: string | null = null,
): Promise<void> {
  const problem = notePathProblem(path)
  if (problem !== null) throw new EditRefused(problem, 'bad_request')
  if ((await readText(run, config, path)) !== after) {
    throw new EditRefused('The note was changed again since, so it is not put back.')
  }
  const result = await run({
    binary: 'synapse',
    args: ['vault-write', path],
    config,
    ...(contentRoot === null ? {} : { env: { SYNAPSE_CONTENT_ROOT: contentRoot } }),
    stdin: before,
  })
  if (result.code !== 0) {
    throw new EditRefused(
      `The note could not be put back: ${result.stderr.trim()}`.trim(),
      'unavailable',
    )
  }
}

// The lines of the frontmatter of a note, between its first two lines of `---`.
function frontmatterLines(text: string): string[] {
  const lines = text.split('\n')
  if (lines[0]?.trim() !== '---') return []
  const end = lines.indexOf('---', 1)
  return end === -1 ? [] : lines.slice(1, end)
}

// Sets the status of a task note: a note that has a task id and a status. It is for a person to ask,
// from the page, and never for an agent, which does not set DONE; the program writes the one field,
// as an agent's tools do, and the time it was updated.
export async function setNoteStatus(
  run: CliRunner,
  config: AppConfig,
  path: string,
  status: NoteStatus,
  // Where the program finds the schemas it checks a note against, when the program cannot tell.
  contentRoot: string | null = null,
): Promise<void> {
  const problem = notePathProblem(path)
  if (problem !== null) throw new EditRefused(problem, 'bad_request')
  const lines = frontmatterLines(await readText(run, config, path))
  if (!lines.some((l) => l.startsWith('task_id:')) || !lines.some((l) => l.startsWith('status:'))) {
    throw new EditRefused('Only a task note has a status.', 'bad_request')
  }
  const env = contentRoot === null ? {} : { env: { SYNAPSE_CONTENT_ROOT: contentRoot } }
  const set = await run({
    binary: 'synapse',
    args: ['frontmatter', 'set', path, 'status', status],
    config,
    ...env,
  })
  if (set.code !== 0) {
    throw new EditRefused(`The status could not be set: ${set.stderr.trim()}`.trim(), 'unavailable')
  }
  const now = await run({ binary: 'synapse', args: ['now'], config })
  const stamp = now.stdout.trim()
  if (now.code === 0 && stamp !== '') {
    await run({
      binary: 'synapse',
      args: ['frontmatter', 'set', path, 'updated', stamp],
      config,
      ...env,
    })
  }
}
