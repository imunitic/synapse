// The commits the Git tab of the Changes sidebar shows for a terminal session: those of the branch
// its harness is on, in the folder its changes are taken from, and what one of them changed. Read
// when the tab is shown, when the window comes back into use, and when the session's baseline
// changes, which a branch switch does; not polled. Read-only.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { Commit } from '../../shared/changes.ts'
import { changeSet, type ChangeSet } from '../domain/changes.ts'
import { parseUnifiedDiff, type FileDiff } from '../domain/unified-diff.ts'
import { transport } from '../transport/index.ts'
import { baselineOf, onBaselineChange } from './change-baselines.ts'

export type CommitListState =
  // No session, or the sidebar or the tab is not shown.
  | { status: 'none' }
  // The session's folder is not known yet.
  | { status: 'waiting' }
  | { status: 'loading' }
  | { status: 'no-repository' }
  | { status: 'failed'; error: string }
  | { status: 'ready'; commits: Commit[]; more: boolean; loadingMore: boolean }

export type CommitViewState =
  | { status: 'none' }
  | { status: 'loading' }
  | { status: 'failed'; error: string }
  | { status: 'ready'; hash: string; set: ChangeSet }

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function useCommits(
  session: string | null,
  shown: boolean,
  commit: string | null,
): {
  list: CommitListState
  view: CommitViewState
  // The folder the commits are of, for reading a new file of one.
  readFile: ((path: string) => Promise<FileDiff | null>) | null
  refresh: () => void
  loadMore: () => void
} {
  const [list, setList] = useState<CommitListState>({ status: 'none' })
  const [view, setView] = useState<CommitViewState>({ status: 'none' })
  // Changes when a session's baseline does, which is when its folder or branch may have.
  const [tick, setTick] = useState(0)
  useEffect(() => onBaselineChange(() => setTick((n) => n + 1)), [])
  const folder = session === null ? null : (baselineOf(session)?.folder ?? null)
  // What is looked at, so that an answer for another is let go.
  const latest = useRef('')
  const key = `${session ?? ''}|${folder ?? ''}`
  latest.current = key

  const readList = useCallback(
    async (first: boolean) => {
      if (session === null || !shown) {
        setList({ status: 'none' })
        return
      }
      if (folder === null) {
        setList({ status: 'waiting' })
        return
      }
      const asked = key
      if (first) setList({ status: 'loading' })
      try {
        const answer = await transport.listCommits(folder)
        if (latest.current !== asked) return
        setList(
          answer.repository
            ? { status: 'ready', commits: answer.commits, more: answer.more, loadingMore: false }
            : { status: 'no-repository' },
        )
      } catch (error) {
        if (latest.current === asked) setList({ status: 'failed', error: messageOf(error) })
      }
    },
    [session, shown, folder, key],
  )

  // Another session, its baseline changing, or the tab being shown, reads the list from the start.
  useEffect(() => {
    void readList(true)
  }, [readList, tick])

  // The window coming back into use reads it again, keeping what is shown meanwhile.
  useEffect(() => {
    if (!shown) return
    const again = () => {
      if (document.visibilityState === 'visible') void readList(false)
    }
    window.addEventListener('focus', again)
    document.addEventListener('visibilitychange', again)
    return () => {
      window.removeEventListener('focus', again)
      document.removeEventListener('visibilitychange', again)
    }
  }, [shown, readList])

  const loadMore = useCallback(() => {
    if (list.status !== 'ready' || !list.more || list.loadingMore || folder === null) return
    const last = list.commits[list.commits.length - 1]
    if (last === undefined) return
    const asked = key
    setList({ ...list, loadingMore: true })
    transport
      .listCommits(folder, last.hash)
      .then((answer) => {
        if (latest.current !== asked) return
        setList((before) =>
          before.status === 'ready'
            ? {
                status: 'ready',
                commits: [...before.commits, ...answer.commits],
                more: answer.more,
                loadingMore: false,
              }
            : before,
        )
      })
      .catch((error: unknown) => {
        if (latest.current === asked) setList({ status: 'failed', error: messageOf(error) })
      })
  }, [list, folder, key])

  // The commit that is shown, read when it is chosen.
  useEffect(() => {
    if (!shown || commit === null || folder === null) {
      setView({ status: 'none' })
      return
    }
    let live = true
    setView({ status: 'loading' })
    transport
      .commitChanges(folder, commit)
      .then((answer) => {
        if (live)
          setView({ status: 'ready', hash: commit, set: changeSet(answer.patch, answer.added) })
      })
      .catch((error: unknown) => {
        if (live) setView({ status: 'failed', error: messageOf(error) })
      })
    return () => {
      live = false
    }
  }, [shown, commit, folder, tick])

  const readFile = useMemo(
    () =>
      folder === null || commit === null
        ? null
        : (path: string) =>
            transport
              .commitChanges(folder, commit, path)
              .then((answer) => parseUnifiedDiff(answer.patch)[0] ?? null),
    [folder, commit],
  )

  const refresh = useCallback(() => {
    void readList(false)
    // A commit does not change, but a page that could not read it tries again.
    if (commit !== null && folder !== null) setTick((n) => n + 1)
  }, [readList, commit, folder])

  return { list, view, readFile, refresh, loadMore }
}
