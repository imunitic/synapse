// What the step visits of a run reported, read from its record as they are wanted: the newest
// finished visit when it first appears, an older one when its row is first opened. A visit is read
// once; another run starts with none.

import { useCallback, useEffect, useRef, useState } from 'react'
import type { RecordedSession } from '../domain/activity.ts'
import type { Visit } from '../domain/progress.ts'
import { readVisitOutput, type VisitOutputRead } from '../domain/visit-outputs.ts'
import { transport } from '../transport/index.ts'

export function useVisitOutputs(
  id: string,
  visits: readonly Visit[],
  sessions: readonly (readonly RecordedSession[])[],
): { outputs: ReadonlyMap<number, VisitOutputRead>; read: (visit: Visit) => void } {
  const [outputs, setOutputs] = useState<ReadonlyMap<number, VisitOutputRead>>(new Map())
  // The visits asked for, of the run in `current`.
  const asked = useRef(new Set<number>())
  const current = useRef(id)
  const sessionsRef = useRef(sessions)
  sessionsRef.current = sessions

  if (current.current !== id) {
    current.current = id
    asked.current = new Set()
  }
  useEffect(() => {
    setOutputs(new Map())
  }, [id])

  const read = useCallback(
    (visit: Visit) => {
      if (asked.current.has(visit.n)) return
      asked.current.add(visit.n)
      readVisitOutput(transport, id, visit, sessionsRef.current[visit.n - 1] ?? [])
        .catch((): VisitOutputRead => ({ status: 'not-recorded' }))
        .then((result) => {
          if (current.current !== id) return
          setOutputs((before) => new Map(before).set(visit.n, result))
        })
    },
    [id],
  )

  // The newest finished visit is read when it first appears.
  const newest = visits.findLast((v) => v.outcome !== null)
  const newestRef = useRef(newest)
  newestRef.current = newest
  const newestN = newest?.n
  useEffect(() => {
    if (newestN !== undefined && newestRef.current !== undefined) read(newestRef.current)
  }, [read, newestN])

  return { outputs, read }
}
