// What the thing being looked at has changed: a terminal session's working folder against the
// snapshot taken when it started, or the patches a run kept in its record. Asked for again now and
// then while the window is in use. Each answer says where HEAD is, and a session that has switched
// branches is compared with the snapshot of the branch it is on (see change-baselines.ts).

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { changeSet, type ChangeSet, type ChangesBase } from '../domain/changes.ts'
import {
  changeLabel,
  liveChange,
  readRunChanges,
  type RecordedChange,
} from '../domain/run-changes.ts'
import { transport } from '../transport/index.ts'
import { baselineOf, followHead, onBaselineChange, type Baseline } from './change-baselines.ts'

// What is being looked at.
export type ChangesSource =
  { kind: 'session'; session: string; base: ChangesBase } | { kind: 'run'; executionId: string }

// The step of a run that is running, for the changes it has made so far. `calls` goes up when a tool
// call that can change files has finished, which is when they are asked for again.
export interface LiveChanges {
  step: string
  visit: number
  attempt: number
  calls: number
}

// The changes of one part of what is looked at: a session has one, a run one for each recorded
// session of a step.
export interface ChangeGroup {
  id: string
  // Which step it is of, empty for a session.
  label: string
  // The visit of the run it is of, from 1; none for a session.
  visit: number | null
  set: ChangeSet
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
      // Where a new file's content is read from, for a session; a run has it in its patches.
      origin: (Baseline & { tree: string }) | null
      // The branch, or commit, a session's snapshot is of, once the session has switched to it,
      // which is when its snapshot was taken. None while the session is where it began.
      position: { head: string; switched: boolean } | null
    }

function positionOf(baseline: Baseline): { head: string; switched: boolean } | null {
  if (baseline.switched !== true || baseline.head === undefined || baseline.head === null)
    return null
  return { head: baseline.head, switched: true }
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

function keyOf(source: ChangesSource | null): string | null {
  if (source === null) return null
  return source.kind === 'session'
    ? `session:${source.session}:${source.base}`
    : `run:${source.executionId}`
}

export function useChanges(
  source: ChangesSource | null,
  open: boolean,
  live: LiveChanges | null = null,
): { state: ChangesState; refresh: () => void } {
  const [recorded, setState] = useState<ChangesState>({ status: 'none' })
  // What the recorded patches of the run are, to name the live one among them.
  const [patches, setPatches] = useState<RecordedChange[]>([])
  // The changes of the running step, asked for apart from the clock: each answer writes the folder
  // into git objects. It is kept with the session it is of.
  const [liveGroup, setLiveGroup] = useState<{ key: string; change: RecordedChange } | null>(null)
  // Changes when the snapshot of a session is taken, and asks for the changes again at once.
  const [tick, setTick] = useState(0)
  const asking = useRef(false)
  // Asked for while a read was going on: it is read again when that one is done, so that what was
  // written meanwhile is not missed.
  const queued = useRef(false)
  // What is being looked at, so that the answer for another is let go.
  const latest = useRef<ChangesSource | null>(null)
  const key = keyOf(source)
  const liveKey =
    live === null || source === null || source.kind !== 'run'
      ? null
      : `${key}:${live.step}:${live.visit}:${live.attempt}`
  const liveRef = useRef<{ key: string | null; live: LiveChanges | null }>({
    key: null,
    live: null,
  })
  liveRef.current = { key: liveKey, live }

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
      if (what.kind === 'session' && baseline !== null && baseline.tree !== null) {
        const { folder } = baseline
        let tree = baseline.tree
        if (what.base === 'commit') {
          // The last commit is read each time, since the agent may commit.
          const head = (await transport.snapshotChanges(folder, 'head')).tree
          if (head === null) {
            if (current()) setState({ status: 'no-repository' })
            return
          }
          tree = head
        }
        const answer = await transport.diffChanges(folder, tree)
        // A branch switch changes the baseline, which asks for the changes again.
        if (answer.repository && current()) void followHead(transport, what.session, answer.head)
        if (current()) {
          setState(
            answer.repository
              ? {
                  status: 'ready',
                  kind: 'session',
                  base: what.base,
                  groups: [
                    {
                      id: 'session',
                      label: '',
                      visit: null,
                      set: changeSet(answer.patch, answer.added),
                    },
                  ],
                  origin: { folder, tree },
                  position: positionOf(baseline),
                }
              : { status: 'no-repository' },
          )
        }
      } else if (what.kind === 'run') {
        const run = await readRunChanges(transport, what.executionId)
        if (current()) {
          setPatches(run.changes)
          setState({
            status: 'ready',
            kind: 'run',
            base: null,
            groups: run.changes.map((change) => ({
              id: `${change.visit}-${change.attempt}`,
              label: changeLabel(change, run.changes),
              visit: change.visit,
              set: change.set,
            })),
            origin: null,
            position: null,
          })
        }
      }
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

  // The changes of the running step, with what it has made so far. A failed read keeps what was
  // shown: the next one will say.
  const askLive = useCallback(async () => {
    const { key: asked, live: now } = liveRef.current
    const what = latest.current
    if (asked === null || now === null || what === null || what.kind !== 'run') return
    try {
      const run = await readRunChanges(transport, what.executionId, now.step)
      if (liveRef.current.key !== asked) return
      const change = liveChange(run, now)
      setLiveGroup(change === null ? null : { key: asked, change })
    } catch {
      // Left as it was.
    }
  }, [])

  // The running step is asked for once when the sidebar opens or the step starts, and after each
  // tool call that can have changed files; never while it is shut, never on the clock.
  const liveCalls = live?.calls ?? 0
  useEffect(() => {
    if (open && liveKey !== null) void askLive()
  }, [open, liveKey, liveCalls, askLive])

  // The step ended: its live changes go, and the patch it saved is read.
  const wasLive = useRef(false)
  useEffect(() => {
    if (liveKey === null) {
      setLiveGroup(null)
      if (wasLive.current) void ask(latest.current, false)
    }
    wasLive.current = liveKey !== null
  }, [liveKey, ask])

  // Another thing, or a session's snapshot arriving, is looked at from the start.
  useEffect(() => {
    latest.current = source
    void ask(source, true)
    // The source is its key: a new object with the same key is the same thing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, tick, ask])

  // Opening the sidebar reads them again at once, not at the next turn of the clock.
  useEffect(() => {
    if (open) void ask(latest.current, false)
  }, [open, key, ask])

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
    void askLive()
  }, [ask, askLive])

  // The recorded groups of a run, and the live one while its step is still running.
  const state = useMemo<ChangesState>(() => {
    if (
      recorded.status !== 'ready' ||
      recorded.kind !== 'run' ||
      liveGroup === null ||
      liveGroup.key !== liveKey
    )
      return recorded
    const id = `${liveGroup.change.visit}-${liveGroup.change.attempt}`
    if (recorded.groups.some((g) => g.id === id)) return recorded
    return {
      ...recorded,
      groups: [
        ...recorded.groups,
        {
          id,
          label: changeLabel(liveGroup.change, [...patches, liveGroup.change]),
          visit: liveGroup.change.visit,
          set: liveGroup.change.set,
        },
      ],
    }
  }, [recorded, liveGroup, liveKey, patches])
  return { state, refresh }
}
