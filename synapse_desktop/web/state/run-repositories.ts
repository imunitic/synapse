// The folders a person has a run show besides, or instead of, the one it works in: the repositories
// added to it, the folders its view was moved to, and which of these the view is in now. For each
// folder, the snapshot it stood at when it was first kept for the run and the one it stood at when
// the run ended. Both are pinned in the repository under
// refs/synapse/desktop/<execution-id>/<folder-key>/, so that git keeps them, and the refs are deleted
// when the run's record is gone. These are the app's own refs, one set for each folder, so the linked
// worktrees of one repository each keep their own. Kept in localStorage, so a run keeps its folders
// after the app is closed.

import type { Transport } from '../../shared/transport.ts'

export interface RunRepository {
  // Without trailing separators.
  folder: string
  // Names this folder's refs for this run.
  key: string
  // The records directory of the run when the folder was first kept: its refs are deleted only when
  // that directory is listed and the run is not in it. Null when there was none.
  records: string | null
  // The tree of HEAD when the folder was first kept.
  start: string
  // The working tree when the run ended; null until it is pinned.
  end: string | null
}

// What is kept for one run. Each folder is in one of the two lists.
interface RunFolders {
  // The folder the view was moved to, one of movedTo; null while it shows the run's own.
  shown: string | null
  // In the order added.
  added: RunRepository[]
  // The folders the view was moved to, the one it is in and those it has left.
  movedTo: RunRepository[]
}

const NOTHING: RunFolders = { shown: null, added: [], movedTo: [] }

const KEY = 'synapse-desktop.run-folders'

// Kept for this page as well; storage may be missing or full.
let kept: Record<string, RunFolders> | null = null
const listeners = new Set<() => void>()

function readAll(): Record<string, RunFolders> {
  if (kept !== null) return kept
  try {
    const raw = localStorage.getItem(KEY)
    const parsed: unknown = raw === null ? {} : JSON.parse(raw)
    kept =
      typeof parsed === 'object' && parsed !== null ? (parsed as Record<string, RunFolders>) : {}
  } catch {
    kept = {}
  }
  return kept
}

function writeAll(all: Record<string, RunFolders>): void {
  kept = all
  try {
    localStorage.setItem(KEY, JSON.stringify(all))
  } catch {
    // Not kept beyond this page.
  }
  for (const listener of listeners) listener()
}

// Told when the folders of a run, or the one its view is in, change; the way to stop is what this
// returns.
export function onRunRepositoriesChange(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

function foldersOf(executionId: string): RunFolders {
  return readAll()[executionId] ?? NOTHING
}

// Every folder kept for a run, shown or not.
function everyFolderOf({ added, movedTo }: RunFolders): RunRepository[] {
  return [...added, ...movedTo]
}

// A run with no folder is not kept.
function keep(executionId: string, run: RunFolders): void {
  const all = { ...readAll() }
  if (everyFolderOf(run).length === 0) delete all[executionId]
  else all[executionId] = run
  writeAll(all)
}

// Forgets what this page holds, so that the next read is of localStorage; for the tests.
export function rereadRunRepositories(): void {
  kept = null
}

export function runRepositoriesOf(executionId: string): RunRepository[] {
  return foldersOf(executionId).added
}

// The folder the run's view was moved to; null while it shows the run's own.
export function runFolderOf(executionId: string): string | null {
  return foldersOf(executionId).shown
}

// The folders a run's changes are read from, in the order they are shown: the folder the view was
// moved to, with the trees kept for it, or else the run's own, with the trees the run recorded, when
// it recorded a start; then the added repositories. A folder with no end has none yet, or was never
// pinned one. The run's own folder is never listed as an added one.
export function runFoldersShown(
  executionId: string,
  own: { directory: string | null; start: string | null; end: string | null },
): { folder: string; start: string; end: string | null }[] {
  const { shown, added, movedTo } = foldersOf(executionId)
  const { directory, start, end } = own
  const first =
    movedTo.find((one) => one.folder === shown) ??
    (directory !== null && start !== null ? { folder: directory, start, end } : undefined)
  const ownFolder = directory === null ? null : withoutTrailingSeparators(directory)
  const others = added.filter((one) => one.folder !== ownFolder)
  return [...(first === undefined ? [] : [first]), ...others].map(({ folder, start, end }) => ({
    folder,
    start,
    end,
  }))
}

function runRef(executionId: string, key: string, end: 'start' | 'end'): string {
  return `desktop/${executionId}/${key}/${end}`
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// A root is left as it is: `/`, and a drive such as `C:\`, which without its separator would mean
// the drive's current folder.
function withoutTrailingSeparators(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, '')
  return trimmed === '' || /^[A-Za-z]:$/.test(trimmed) ? path : trimmed
}

// Whether a folder is another one or contains it. A root contains the folders under it.
function contains(outer: string, inner: string): boolean {
  const [o, i] = [withoutTrailingSeparators(outer), withoutTrailingSeparators(inner)]
  // A root keeps its separator, which is not to be doubled.
  const above = o.replace(/[\\/]+$/, '')
  return i === o || i.startsWith(`${above}/`) || i.startsWith(`${above}\\`)
}

type StartTransport = Pick<Transport, 'snapshotChanges' | 'pinSnapshot' | 'getPaths'>

// The folders whose start is being taken, so that each has one entry and one set of refs; for each,
// what anyone else who asks for it meanwhile is told.
const taking = new Map<string, string>()

// Takes the tree of the folder's HEAD and pins it as the run's start there. The entry to keep, or why
// there is none; nothing is pinned then.
async function takeStart(
  transport: StartTransport,
  executionId: string,
  folder: string,
): Promise<RunRepository | string> {
  const { tree } = await transport.snapshotChanges(folder, 'head')
  if (tree === null) return 'That folder is not in a git repository.'
  const { recordsDir } = await transport.getPaths()
  const key = crypto.randomUUID()
  await transport.pinSnapshot(folder, runRef(executionId, key, 'start'), tree)
  return { folder, key, records: recordsDir, start: tree, end: null }
}

// Adds a repository to a run: the tree of its HEAD is pinned as the run's start in it, and a folder
// the view was moved to earlier has the start it has. Null when it is added, and otherwise why it is
// not. The folder the view is in is refused. When the run's own folder is in a repository, that folder
// and a folder it is inside are refused, moved to earlier or not: they are most likely the run's own
// repository, whose changes the run's own folder shows. When it is not in one (the home folder, say),
// the run shows nothing there.
// A folder inside the run's folder is left to the host: it refuses to pin in a folder that is not the
// root of its repository, so a plain subfolder of the run's repository is refused there, and a nested
// repository (a submodule, say) is added.
export async function addRunRepository(
  transport: StartTransport,
  executionId: string,
  runDirectory: string | null,
  typed: string,
): Promise<string | null> {
  if (typed.trim() === '') return 'Type the path of a folder.'
  const folder = withoutTrailingSeparators(typed.trim())
  const run = foldersOf(executionId)
  if (run.added.some((one) => one.folder === folder)) return 'That repository is added already.'
  if (run.shown === folder) return 'That repository is shown already.'
  const underWay = JSON.stringify([executionId, folder])
  const busy = taking.get(underWay)
  if (busy !== undefined) return busy
  taking.set(underWay, 'That repository is being added.')
  try {
    if (runDirectory !== null && contains(folder, runDirectory)) {
      const own = await transport.snapshotChanges(runDirectory, 'head')
      if (own.tree !== null)
        return runFolderOf(executionId) === null
          ? 'That folder is in the run’s own repository, which is shown already.'
          : 'That folder is in the run’s own repository. To see it, type the run’s own folder in the folder bar.'
    }
    // Read here: the view may have moved while the run's own folder was looked at.
    const current = foldersOf(executionId)
    if (current.shown === folder) return 'That repository is shown already.'
    const earlier = current.movedTo.find((one) => one.folder === folder)
    if (earlier !== undefined) {
      keep(executionId, {
        ...current,
        added: [...current.added, earlier],
        movedTo: current.movedTo.filter((one) => one !== earlier),
      })
      return null
    }
    const taken = await takeStart(transport, executionId, folder)
    if (typeof taken === 'string') return taken
    const now = foldersOf(executionId)
    keep(executionId, { ...now, added: [...now.added, taken] })
    return null
  } catch (error) {
    return messageOf(error)
  } finally {
    taking.delete(underWay)
  }
}

// The runs whose view is moving.
const moving = new Set<string>()

// Moves a run's view to a folder, which is shown in place of the run's own. A folder not kept for the
// run has the tree of its HEAD pinned as the run's start in it; a kept one has the start it has, and an
// added repository stops being listed as added. The folder moved away from stays kept. The run's own
// folder takes nothing, whether or not it is in a repository. Null when the view is in the folder, and
// otherwise why it could not move.
export async function moveRunFolder(
  transport: StartTransport,
  executionId: string,
  runDirectory: string,
  typed: string,
): Promise<string | null> {
  if (typed.trim() === '') return 'Type the path of a folder.'
  if (moving.has(executionId)) return 'The view is moving to another folder.'
  const folder = withoutTrailingSeparators(typed.trim())
  const run = foldersOf(executionId)
  if (folder === withoutTrailingSeparators(runDirectory)) {
    if (run.shown !== null) keep(executionId, { ...run, shown: null })
    return null
  }
  const earlier = everyFolderOf(run).find((one) => one.folder === folder)
  if (earlier !== undefined) {
    if (run.shown !== folder)
      keep(executionId, {
        shown: folder,
        added: run.added.filter((one) => one !== earlier),
        movedTo: [...run.movedTo.filter((one) => one !== earlier), earlier],
      })
    return null
  }
  const underWay = JSON.stringify([executionId, folder])
  const busy = taking.get(underWay)
  if (busy !== undefined) return busy
  taking.set(underWay, 'The view is moving to that folder.')
  moving.add(executionId)
  try {
    const taken = await takeStart(transport, executionId, folder)
    if (typeof taken === 'string') return taken
    const now = foldersOf(executionId)
    keep(executionId, { ...now, shown: folder, movedTo: [...now.movedTo, taken] })
    return null
  } catch (error) {
    return messageOf(error)
  } finally {
    taking.delete(underWay)
    moving.delete(executionId)
  }
}

// Deletes both of the app's refs for one folder of a run. A ref that cannot be deleted is left.
async function unpinBoth(
  transport: Pick<Transport, 'unpinSnapshot'>,
  executionId: string,
  { folder, key }: RunRepository,
): Promise<void> {
  for (const end of ['start', 'end'] as const) {
    try {
      await transport.unpinSnapshot(folder, runRef(executionId, key, end))
    } catch {
      // Left in the repository.
    }
  }
}

// Takes an added repository off a run: it is forgotten, as a folder moved to as well, and both of the
// app's refs for it are deleted. It is forgotten even when a ref cannot be deleted.
export async function removeRunRepository(
  transport: Pick<Transport, 'unpinSnapshot'>,
  executionId: string,
  folder: string,
): Promise<void> {
  const run = foldersOf(executionId)
  const repository = run.added.find((one) => one.folder === folder)
  if (repository === undefined) return
  // Forgotten first, so that a move to the folder meanwhile takes a start with refs of its own.
  keep(executionId, { ...run, added: run.added.filter((one) => one !== repository) })
  await unpinBoth(transport, executionId, repository)
}

// The runs whose ends are being pinned, so that each end is pinned once.
const ending = new Set<string>()

// Pins the working tree of each folder kept for a run that has no end yet, shown or not, as the run's
// end in it. A folder whose snapshot or pin fails keeps no end, and is tried again at the next call.
export async function endRunRepositories(
  transport: Pick<Transport, 'snapshotChanges' | 'pinSnapshot'>,
  executionId: string,
): Promise<void> {
  if (ending.has(executionId)) return
  ending.add(executionId)
  try {
    for (const repository of everyFolderOf(foldersOf(executionId))) {
      if (repository.end !== null) continue
      try {
        const { tree } = await transport.snapshotChanges(repository.folder)
        if (tree === null) continue
        await transport.pinSnapshot(
          repository.folder,
          runRef(executionId, repository.key, 'end'),
          tree,
        )
        const now = foldersOf(executionId)
        const ended = (one: RunRepository) =>
          one.key === repository.key ? { ...one, end: tree } : one
        keep(executionId, {
          ...now,
          added: now.added.map(ended),
          movedTo: now.movedTo.map(ended),
        })
      } catch {
        // Tried again at the next call.
      }
    }
  } finally {
    ending.delete(executionId)
  }
}

// Deletes the app's refs of each run kept here whose record is gone from the records directory that
// was listed, and forgets the run, the folder its view was in included. Runs with a folder kept under
// another records directory, or under none, are kept: their records were not listed. A ref that
// cannot be deleted is left; the run is forgotten all the same. With no records directory (no work
// directory), nothing was listed and nothing is gone.
export async function forgetGoneRuns(
  transport: Pick<Transport, 'unpinSnapshot'>,
  recordsDir: string | null,
  knownIds: readonly string[],
): Promise<void> {
  if (recordsDir === null) return
  const known = new Set(knownIds)
  const gone = Object.entries(readAll())
    .filter(
      ([id, run]) =>
        !known.has(id) && everyFolderOf(run).every((one) => one.records === recordsDir),
    )
    .map(([id]) => id)
  for (const executionId of gone) {
    for (const repository of everyFolderOf(foldersOf(executionId)))
      await unpinBoth(transport, executionId, repository)
    keep(executionId, NOTHING)
  }
}
