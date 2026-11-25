// Where a terminal session's folder stood when the session started: the snapshot that its changes
// are taken against, kept for the life of the tab so that a page that is loaded again still has it.
// When the harness switches branches, a new snapshot is taken of the branch it switched to, and the
// changes start over from it: the difference between two branches is not something the session did,
// and a snapshot kept from an earlier visit would be of a branch that has moved on since. The baseline of each
// other folder the session has worked in, such as a worktree it entered, is kept the same way.

import type { Transport } from '../../shared/transport.ts'

export interface Baseline {
  // The folder the session works in, as the host says it is.
  folder: string
  // The snapshot of its working tree; null when the folder is not in a git repository.
  tree: string | null
  // The conversation of a harness in the session that the snapshot was taken for, when it was: a
  // shell that started in one folder has a harness started in another.
  source?: string
  // Where HEAD was when the snapshot was taken: a branch, or a commit when HEAD was detached. Missing
  // in a baseline kept before positions were, which takes the next one it is told of.
  head?: string | null
  // Whether the snapshot was taken when the session switched to that position, not when it began.
  switched?: boolean
  // The baselines of the other folders the session has been in, by folder.
  others?: Record<string, Baseline>
}

const KEY = 'synapse-desktop.change-baselines'

function readAll(): Record<string, Baseline> {
  try {
    const raw = sessionStorage.getItem(KEY)
    const parsed: unknown = raw === null ? {} : JSON.parse(raw)
    return typeof parsed === 'object' && parsed !== null ? (parsed as Record<string, Baseline>) : {}
  } catch {
    return {}
  }
}

// Kept for the session of the browser; storage may be missing or full, and then it is kept here.
const kept = new Map<string, Baseline>()
const listeners = new Set<() => void>()

export function baselineOf(session: string): Baseline | null {
  return kept.get(session) ?? readAll()[session] ?? null
}

export function keepBaseline(session: string, baseline: Baseline | null): void {
  if (baseline === null) kept.delete(session)
  else kept.set(session, baseline)
  try {
    const all = readAll()
    if (baseline === null) delete all[session]
    else all[session] = baseline
    sessionStorage.setItem(KEY, JSON.stringify(all))
  } catch {
    // Not kept beyond this page.
  }
  for (const listener of listeners) listener()
}

// Told when a baseline is kept or dropped; the way to stop is what this returns.
export function onBaselineChange(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

// Takes the session's baseline now, unless it has one. A folder that is not in a git repository has
// a baseline with no snapshot, which says there is nothing to show; none is kept when git cannot be
// asked.
export async function ensureBaseline(
  transport: Pick<Transport, 'snapshotChanges'>,
  session: string,
  folder: string,
): Promise<void> {
  if (baselineOf(session) !== null) return
  try {
    const { tree, head } = await transport.snapshotChanges(folder)
    if (baselineOf(session) === null) keepBaseline(session, { folder, tree, head })
  } catch {
    // The sidebar says there is nothing to show.
  }
}

// Takes the session's baseline for the folder a harness started in it works in, when its
// conversation appears: that is where the changes to look at will be, whatever folder the session
// began in. Once for each conversation, so a page that is loaded again, and is told of it again,
// keeps the one it has. None is taken when git cannot be asked, and the old one stays.
export async function followBaseline(
  transport: Pick<Transport, 'snapshotChanges'>,
  session: string,
  folder: string,
  source: string,
): Promise<void> {
  if (baselineOf(session)?.source === source) return
  try {
    const { tree, head } = await transport.snapshotChanges(folder)
    if (baselineOf(session)?.source !== source)
      keepBaseline(session, { folder, tree, source, head })
  } catch {
    // The sidebar goes on with the baseline it has.
  }
}

// The sessions whose snapshot for a new position is being taken, so that one is taken at a time.
const following = new Set<string>()

// Follows where HEAD is now, as a diff answer says. A baseline kept before positions were takes it
// as its own. When it is another position, a new snapshot is taken now and becomes the baseline,
// whether or not the session has been on that position before. A folder that is not in a
// repository, or a position of null, changes nothing.
export async function followHead(
  transport: Pick<Transport, 'snapshotChanges'>,
  session: string,
  head: string | null,
): Promise<void> {
  const baseline = baselineOf(session)
  if (baseline === null || baseline.tree === null || head === null) return
  if (baseline.head === undefined || baseline.head === null) {
    keepBaseline(session, { ...baseline, head })
    return
  }
  if (baseline.head === head || following.has(session)) return
  following.add(session)
  try {
    const taken = await transport.snapshotChanges(baseline.folder)
    if (taken.tree === null) return
    // HEAD may have moved again while the snapshot was taken; the tree is of where it is now.
    const next = { tree: taken.tree, head: taken.head ?? head }
    // Let go when the session took another baseline meanwhile.
    const now = baselineOf(session)
    if (
      now?.folder !== baseline.folder ||
      now.source !== baseline.source ||
      now.head !== baseline.head
    ) {
      return
    }
    keepBaseline(session, {
      folder: baseline.folder,
      ...(baseline.source === undefined ? {} : { source: baseline.source }),
      tree: next.tree,
      head: next.head,
      switched: true,
    })
  } catch {
    // The sidebar goes on with the baseline it has, and is asked again at the next look.
  } finally {
    following.delete(session)
  }
}

// The sessions whose baseline for a new folder is being taken, so that one is taken at a time.
const moving = new Set<string>()

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// Moves the session's baseline to the folder a person typed. The baseline of the folder it leaves is
// kept, and is the one restored when it comes back; a folder not been in before is snapshotted now.
// Null when the session is in the folder, and otherwise why it could not move.
export async function followFolder(
  transport: Pick<Transport, 'snapshotChanges'>,
  session: string,
  typed: string,
): Promise<string | null> {
  const folder = typed.trim()
  if (folder === '') return 'Type the path of a folder.'
  const start = baselineOf(session)
  if (start === null) return 'The starting point of this session is not taken yet.'
  if (start.folder === folder) return null
  if (moving.has(session)) return 'The folder is being changed.'
  moving.add(session)
  try {
    let next: Baseline | undefined = start.others?.[folder]
    if (next === undefined) {
      const { tree, head } = await transport.snapshotChanges(folder)
      if (tree === null) return 'That folder is not in a git repository.'
      next = { folder, tree, head, ...(start.source === undefined ? {} : { source: start.source }) }
    }
    // Let go when the session took another baseline meanwhile.
    const now = baselineOf(session)
    if (now?.folder !== start.folder) return 'The session changed folder meanwhile.'
    const { others, ...left } = now
    const rest: Record<string, Baseline> = { ...others }
    delete rest[folder]
    rest[left.folder] = left
    keepBaseline(session, { ...next, others: rest })
    return null
  } catch (error) {
    return messageOf(error)
  } finally {
    moving.delete(session)
  }
}
