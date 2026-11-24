import { useCallback, useMemo, useState } from 'react'
import { readActivity, type Activity } from '../domain/activity.ts'
import { readExecution } from '../domain/executions.ts'
import { changingCalls, liveSession, type LiveSession } from '../domain/live.ts'
import { transport } from '../transport/index.ts'
import { useLoad } from './useLoad.ts'
import { useWatch } from './useWatch.ts'

// What no file shows, such as a run that died, is looked for now and then.
const REFRESH_MS = 10_000

// The transcript of a session that is going on is read again this often. The folder watch cannot be
// relied on for it: a file that grows through a handle the writer keeps open raises no event on
// macOS, so without this the activity would only show when the step ends.
const TRANSCRIPT_MS = 2000

export interface LiveRun {
  live: LiveSession | null
  // What the running session has done so far, or null before its transcript can be read.
  activity: Activity | null
  // How many finished actions can have changed files: it goes up when the changes are worth asking.
  calls: number
}

const NONE: LiveRun = { live: null, activity: null, calls: 0 }

// The session of a headless run that is going on, and its transcript as it grows. Reads nothing
// when there is no run; a transcript that is not there yet is no activity, not an error.
export function useLiveRun(executionId: string | null): LiveRun {
  // Whether the last read of the record showed a session going on: only then is there anything to poll.
  const [running, setRunning] = useState(false)
  const loadRecord = useCallback(
    () =>
      executionId === null
        ? Promise.resolve(null)
        : readExecution(transport, executionId).then((record) => {
            setRunning(liveSession(record.events, record.summary) !== null)
            return { id: executionId, record }
          }),
    [executionId],
  )
  const { state, reload } = useLoad(
    loadRecord,
    executionId === null || !running ? undefined : REFRESH_MS,
  )
  const [changes, setChanges] = useState(0)
  useWatch('work', () => {
    if (executionId === null) return
    reload()
    // The transcript grows under the watched folder; with no session there is none to read.
    if (running) setChanges((n) => n + 1)
  })

  const loaded = state.status === 'ready' ? state.data : null
  const live = useMemo(
    () =>
      loaded === null || loaded.id !== executionId
        ? null
        : liveSession(loaded.record.events, loaded.record.summary),
    [loaded, executionId],
  )
  const transcript = live?.transcript ?? null

  const loadTranscript = useCallback(async () => {
    if (transcript === null) return null
    try {
      return { path: transcript, activity: readActivity(await transport.readText(transcript)) }
    } catch {
      return null
    }
  }, [transcript])
  const { state: read } = useLoad(
    loadTranscript,
    transcript === null ? undefined : TRANSCRIPT_MS,
    changes,
  )

  // What was read for another session, such as the one before, is not this one's.
  const seen = read.status === 'ready' && read.data?.path === transcript ? read.data.activity : null
  if (live === null) return NONE
  return { live, activity: seen, calls: seen === null ? 0 : changingCalls(seen) }
}
