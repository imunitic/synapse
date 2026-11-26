// What the thing being looked at has changed, one group for each repository it is shown in. A
// terminal session: its working folder, and each folder shown next to it, against the snapshot taken
// of it (see change-baselines.ts). A run: the folder it works in, from the snapshot pinned when it
// started to the one pinned when it ended (or the working tree while it runs), and the same for each
// repository added to it (see run-repositories.ts). Asked for again now and then while the window is
// in use. Each answer of a session says where HEAD is, and a session that has switched branches is
// compared with the snapshot of the branch it is on.

import { useCallback, useEffect, useRef, useState } from 'react'
import { baseName, changeSet, type ChangeSet, type ChangesBase } from '../domain/changes.ts'
import { readRunChanges } from '../domain/run-changes.ts'
import { transport } from '../transport/index.ts'
import {
  baselineOf,
  followHead,
  followOtherHead,
  onBaselineChange,
  type Baseline,
} from './change-baselines.ts'
import {
  endRunRepositories,
  onRunRepositoriesChange,
  runRepositoriesOf,
} from './run-repositories.ts'

// What is being looked at.
export type ChangesSource =
  { kind: 'session'; session: string; base: ChangesBase } | { kind: 'run'; executionId: string }

// The changes of one repository of what is looked at.
export interface ChangeGroup {
  // The folder, which names the group.
  id: string
  // The folder's own name, for its heading.
  name: string
  folder: string
  set: ChangeSet
  // What the changes are between, for reading a file's content: two snapshots, or a snapshot and
  // the working tree now when after is null.
  origin: { folder: string; before: string; after: string | null }
}

export type ChangesState =
  // Nothing is being looked at: the page is not a terminal session or a run.
  | { status: 'none' }
  // The session's snapshot is not taken yet.
  | { status: 'waiting' }
  | { status: 'loading' }
  // The folder is not in a git repository, so there is no diff to show.
  | { status: 'no-repository' }
  | { status: 'failed'; error: string }
  | {
      status: 'ready'
      kind: 'session' | 'run'
      groups: ChangeGroup[]
      // What a session's changes are against; none for a run.
      base: ChangesBase | null
      // The branch, or commit, a session's snapshot is of, once the session has been on more than
      // one; whether that snapshot was taken on the switch to it. None while there was only one.
      position: { head: string; switched: boolean } | null
      // A run that has ended is shown against the working tree now, because it has no end snapshot.
      live: boolean
      // A snapshot the run pinned is no longer in its repository.
      gone: boolean
    }

type ReadyState = Extract<ChangesState, { status: 'ready' }>

function positionOf(baseline: Baseline): { head: string; switched: boolean } | null {
  const others = Object.keys(baseline.kept ?? {})
  if (others.length === 0 || baseline.head === undefined || baseline.head === null) return null
  return { head: baseline.head, switched: baseline.switched ?? false }
}

// How many files the changes hold, for the icon.
export function fileCount(state: ChangesState): number | null {
  return state.status === 'ready'
    ? state.groups.reduce((sum, group) => sum + group.set.files.length, 0)
    : null
}

// How often the changes are asked for again while the sidebar shows them, and while it is shut and
// only its count is wanted.
const OPEN_MS = 4000
const SHUT_MS = 15000

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

// Whether a host said a snapshot is not in the repository.
function isNotFound(error: unknown): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    (error as { code?: unknown }).code === 'not_found'
  )
}

function keyOf(source: ChangesSource | null): string | null {
  if (source === null) return null
  return source.kind === 'session'
    ? `session:${source.session}:${source.base}`
    : `run:${source.executionId}`
}

function groupOf(
  folder: string,
  set: ChangeSet,
  before: string,
  after: string | null,
): ChangeGroup {
  return { id: folder, name: baseName(folder), folder, set, origin: { folder, before, after } }
}

// One folder of a session against its baseline; null when the folder is not in a repository. The
// position HEAD is at is passed to follow.
async function sessionGroup(
  folder: string,
  baselineTree: string,
  base: ChangesBase,
  follow: (head: string | null) => void,
): Promise<ChangeGroup | null> {
  let before = baselineTree
  if (base === 'commit') {
    // The last commit is read each time, since the agent may commit.
    const head = (await transport.snapshotChanges(folder, 'head')).tree
    if (head === null) return null
    before = head
  }
  const answer = await transport.diffChanges(folder, before)
  if (!answer.repository) return null
  follow(answer.head)
  return groupOf(folder, changeSet(answer.patch, answer.added), before, null)
}

async function readSession(
  what: Extract<ChangesSource, { kind: 'session' }>,
  baseline: Baseline & { tree: string },
  current: () => boolean,
): Promise<ChangesState> {
  // A branch switch changes the baseline, which asks for the changes again.
  const own = await sessionGroup(baseline.folder, baseline.tree, what.base, (head) => {
    if (current()) void followHead(transport, what.session, head)
  })
  if (own === null) return { status: 'no-repository' }
  const groups = [own]
  for (const folder of baseline.shown ?? []) {
    const other = baseline.others?.[folder]
    if (other === undefined || other.tree === null) continue
    const group = await sessionGroup(folder, other.tree, what.base, (head) => {
      if (current()) void followOtherHead(transport, what.session, folder, head)
    })
    if (group !== null) groups.push(group)
  }
  return {
    status: 'ready',
    kind: 'session',
    base: what.base,
    groups,
    position: positionOf(baseline),
    live: false,
    gone: false,
  }
}

async function readRun(executionId: string): Promise<ReadyState> {
  const run = await readRunChanges(transport, executionId)
  const running = run.status === 'running'
  // An ended run pins the end of each repository added to it, once.
  if (!running) await endRunRepositories(transport, executionId)
  const wanted: { folder: string; start: string; end: string | null }[] = []
  if (run.directory !== null && run.snapshots.start !== null)
    wanted.push({ folder: run.directory, start: run.snapshots.start, end: run.snapshots.end })
  for (const added of runRepositoriesOf(executionId))
    if (!wanted.some((one) => one.folder === added.folder)) wanted.push(added)
  const groups: ChangeGroup[] = []
  let live = false
  let gone = false
  for (const { folder, start, end } of wanted) {
    // A run that ended without an end snapshot is shown against the working tree now.
    const after = running ? null : end
    try {
      const answer =
        after === null
          ? await transport.diffChanges(folder, start)
          : await transport.diffChanges(folder, start, undefined, after)
      if (!answer.repository) continue
      if (!running && after === null) live = true
      groups.push(groupOf(folder, changeSet(answer.patch, answer.added), start, after))
    } catch (error) {
      if (!isNotFound(error)) throw error
      gone = true
    }
  }
  return { status: 'ready', kind: 'run', base: null, groups, position: null, live, gone }
}

// `liveCalls` goes up when a tool call of the run that can change files has finished, which is when
// the changes are asked for again while the sidebar is open.
export function useChanges(
  source: ChangesSource | null,
  open: boolean,
  liveCalls = 0,
): { state: ChangesState; refresh: () => void } {
  const [state, setState] = useState<ChangesState>({ status: 'none' })
  // Changes when the snapshot of a session is taken, and asks for the changes again at once.
  const [tick, setTick] = useState(0)
  const asking = useRef(false)
  // Asked for while a read was going on: it is read again when that one is done, so that what was
  // written meanwhile is not missed.
  const queued = useRef(false)
  // What is being looked at, so that the answer for another is let go.
  const latest = useRef<ChangesSource | null>(null)
  const key = keyOf(source)

  useEffect(() => onBaselineChange(() => setTick((n) => n + 1)), [])

  const ask = useCallback(async (what: ChangesSource | null, first: boolean) => {
    if (what === null) {
      setState({ status: 'none' })
      return
    }
    const wanted = keyOf(what)
    const current = () => keyOf(latest.current) === wanted
    let baseline: Baseline | null = null
    if (what.kind === 'session') {
      baseline = baselineOf(what.session)
      if (baseline === null) {
        setState({ status: 'waiting' })
        return
      }
      if (baseline.tree === null) {
        setState({ status: 'no-repository' })
        return
      }
    }
    if (asking.current) {
      queued.current = true
      return
    }
    asking.current = true
    if (first) setState({ status: 'loading' })
    try {
      const next =
        what.kind === 'session' && baseline !== null && baseline.tree !== null
          ? await readSession(what, { ...baseline, tree: baseline.tree }, current)
          : what.kind === 'run'
            ? await readRun(what.executionId)
            : null
      if (next !== null && current()) setState(next)
    } catch (error) {
      if (current()) setState({ status: 'failed', error: messageOf(error) })
    } finally {
      asking.current = false
      if (queued.current) {
        queued.current = false
        void ask(latest.current, false)
      }
    }
  }, [])

  // A repository added to a run, or the end pinned in one, is read again; quietly, as the clock does.
  useEffect(() => onRunRepositoriesChange(() => void ask(latest.current, false)), [ask])

  // Another thing, or a session's snapshot arriving, is looked at from the start.
  useEffect(() => {
    latest.current = source
    void ask(source, true)
    // The source is its key: a new object with the same key is the same thing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, tick, ask])

  // Opening the sidebar reads them again at once, not at the next turn of the clock, and so does
  // each tool call of the run that can have changed files while it is open.
  useEffect(() => {
    if (open) void ask(latest.current, false)
  }, [open, key, liveCalls, ask])

  // Then again now and then, when the window is in use, and when it is come back to.
  useEffect(() => {
    if (key === null) return
    const again = () => {
      if (document.visibilityState === 'visible') void ask(latest.current, false)
    }
    const timer = setInterval(again, open ? OPEN_MS : SHUT_MS)
    window.addEventListener('focus', again)
    return () => {
      clearInterval(timer)
      window.removeEventListener('focus', again)
    }
  }, [key, open, ask])

  const refresh = useCallback(() => {
    void ask(latest.current, false)
  }, [ask])

  return { state, refresh }
}
