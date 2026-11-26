// The repositories a person added to a run, next to the folder the run works in: for each one, the
// snapshot it stood at when it was added and the one it stood at when the run ended. Both are pinned
// in the repository under refs/synapse/runs/<execution-id>/, so that git keeps them, and the refs
// are deleted when the run's record is gone. Kept in localStorage, so a run keeps its repositories
// after the app is closed.

import type { Transport } from '../../shared/transport.ts'

export interface RunRepository {
  folder: string
  // The records directory of the run when the repository was added: its refs are deleted only when
  // that directory is listed and the run is not in it. Null when there was none.
  records: string | null
  // The tree of HEAD when the repository was added.
  start: string
  // The working tree when the run ended; null until it is pinned.
  end: string | null
}

const KEY = 'synapse-desktop.run-repositories'

// Kept for this page as well; storage may be missing or full.
let kept: Record<string, RunRepository[]> | null = null
const listeners = new Set<() => void>()

function readAll(): Record<string, RunRepository[]> {
  if (kept !== null) return kept
  try {
    const raw = localStorage.getItem(KEY)
    const parsed: unknown = raw === null ? {} : JSON.parse(raw)
    kept =
      typeof parsed === 'object' && parsed !== null
        ? (parsed as Record<string, RunRepository[]>)
        : {}
  } catch {
    kept = {}
  }
  return kept
}

function writeAll(all: Record<string, RunRepository[]>): void {
  kept = all
  try {
    localStorage.setItem(KEY, JSON.stringify(all))
  } catch {
    // Not kept beyond this page.
  }
  for (const listener of listeners) listener()
}

// Told when the repositories of a run change; the way to stop is what this returns.
export function onRunRepositoriesChange(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

function keep(executionId: string, repositories: RunRepository[]): void {
  const all = { ...readAll() }
  if (repositories.length === 0) delete all[executionId]
  else all[executionId] = repositories
  writeAll(all)
}

// Forgets what this page holds, so that the next read is of localStorage; for the tests.
export function rereadRunRepositories(): void {
  kept = null
}

export function runRepositoriesOf(executionId: string): RunRepository[] {
  return readAll()[executionId] ?? []
}

export function runRef(executionId: string, end: 'start' | 'end'): string {
  return `runs/${executionId}/${end}`
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function withoutTrailingSeparators(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, '')
  return trimmed === '' ? path : trimmed
}

// Whether a folder is another one or contains it.
function contains(outer: string, inner: string): boolean {
  const [o, i] = [withoutTrailingSeparators(outer), withoutTrailingSeparators(inner)]
  return i === o || i.startsWith(`${o}/`) || i.startsWith(`${o}\\`)
}

// Adds a repository to a run: the tree of its HEAD is pinned as the run's start in it. Null when it
// is added, and otherwise why it is not. When the run's own folder is in a repository, that folder and
// a folder it is inside are refused: they are most likely the run's own repository, whose refs under
// the same names the run pinned itself. When it is not in one (the home folder, say), the run pinned
// nothing there. A folder inside the run's folder is left to the host: it refuses to pin in a folder
// that is not the root of its repository, so a plain subfolder (or a sibling folder) of the run's
// repository is refused there, and a nested repository (a submodule, say) is added. (A linked
// worktree of the run's repository is not told apart.)
export async function addRunRepository(
  transport: Pick<Transport, 'snapshotChanges' | 'pinSnapshot' | 'getPaths'>,
  executionId: string,
  runDirectory: string | null,
  typed: string,
): Promise<string | null> {
  const folder = typed.trim()
  if (folder === '') return 'Type the path of a folder.'
  if (runRepositoriesOf(executionId).some((one) => one.folder === folder))
    return 'That repository is added already.'
  try {
    if (runDirectory !== null && contains(folder, runDirectory)) {
      const own = await transport.snapshotChanges(runDirectory, 'head')
      if (own.tree !== null)
        return 'That folder is in the run’s own repository, which is shown already.'
    }
    const { tree } = await transport.snapshotChanges(folder, 'head')
    if (tree === null) return 'That folder is not in a git repository.'
    const { recordsDir } = await transport.getPaths()
    await transport.pinSnapshot(folder, runRef(executionId, 'start'), tree)
    const now = runRepositoriesOf(executionId)
    if (now.some((one) => one.folder === folder)) return 'That repository is added already.'
    keep(executionId, [...now, { folder, records: recordsDir, start: tree, end: null }])
    return null
  } catch (error) {
    return messageOf(error)
  }
}

// Takes a repository off a run: both of the run's refs in it are deleted, and it is forgotten. A ref
// that cannot be deleted is left; the repository is forgotten all the same.
export async function removeRunRepository(
  transport: Pick<Transport, 'unpinSnapshot'>,
  executionId: string,
  folder: string,
): Promise<void> {
  if (!runRepositoriesOf(executionId).some((one) => one.folder === folder)) return
  for (const end of ['start', 'end'] as const) {
    try {
      await transport.unpinSnapshot(folder, runRef(executionId, end))
    } catch {
      // Left in the repository.
    }
  }
  keep(
    executionId,
    runRepositoriesOf(executionId).filter((one) => one.folder !== folder),
  )
}

// The runs whose ends are being pinned, so that each end is pinned once.
const ending = new Set<string>()

// Pins the working tree of each repository of a run that has no end yet, as the run's end in it. A
// repository whose snapshot or pin fails keeps no end, and is tried again at the next call.
export async function endRunRepositories(
  transport: Pick<Transport, 'snapshotChanges' | 'pinSnapshot'>,
  executionId: string,
): Promise<void> {
  if (ending.has(executionId)) return
  ending.add(executionId)
  try {
    for (const repository of runRepositoriesOf(executionId)) {
      if (repository.end !== null) continue
      try {
        const { tree } = await transport.snapshotChanges(repository.folder)
        if (tree === null) continue
        await transport.pinSnapshot(repository.folder, runRef(executionId, 'end'), tree)
        keep(
          executionId,
          runRepositoriesOf(executionId).map((one) =>
            one.folder === repository.folder ? { ...one, end: tree } : one,
          ),
        )
      } catch {
        // Tried again at the next call.
      }
    }
  } finally {
    ending.delete(executionId)
  }
}

// Deletes the refs of each run kept here whose record is gone from the records directory that was
// listed, and forgets the run. Runs added under another records directory, or under none, are kept:
// their records were not listed. A ref that cannot be deleted is left; the run is forgotten all the
// same. With no records directory (no work directory), nothing was listed and nothing is gone.
export async function forgetGoneRuns(
  transport: Pick<Transport, 'unpinSnapshot'>,
  recordsDir: string | null,
  knownIds: readonly string[],
): Promise<void> {
  if (recordsDir === null) return
  const known = new Set(knownIds)
  const gone = Object.entries(readAll())
    .filter(
      ([id, repositories]) =>
        !known.has(id) &&
        repositories.length > 0 &&
        repositories.every((one) => one.records === recordsDir),
    )
    .map(([id]) => id)
  for (const executionId of gone) {
    for (const { folder } of runRepositoriesOf(executionId)) {
      for (const end of ['start', 'end'] as const) {
        try {
          await transport.unpinSnapshot(folder, runRef(executionId, end))
        } catch {
          // Left in the repository.
        }
      }
    }
    keep(executionId, [])
  }
}
