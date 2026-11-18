import { useEffect, useMemo, useState } from 'react'
import { readSummary, waitingFor } from '../domain/executions.ts'
import { transport } from '../transport/index.ts'

const POLL_MS = 2500

// The runs among `ids` that wait for a person, each with what its agent said. Read from the
// record of each run while there are any, and nothing is read when there are none.
export function useWaitingRuns(ids: readonly string[]): ReadonlyMap<string, string> {
  const key = ids.join(',')
  const wanted = useMemo(() => (key === '' ? [] : key.split(',')), [key])
  const [waiting, setWaiting] = useState<ReadonlyMap<string, string>>(new Map())

  useEffect(() => {
    if (wanted.length === 0) {
      setWaiting((now) => (now.size === 0 ? now : new Map()))
      return
    }
    let current = true
    const read = async () => {
      const found = new Map<string, string>()
      await Promise.all(
        wanted.map(async (id) => {
          const summary = await readSummary(transport, id).catch(() => null)
          const reason = summary === null ? null : waitingFor(summary)
          if (reason !== null) found.set(id, reason)
        }),
      )
      if (current) setWaiting(found)
    }
    void read()
    const timer = setInterval(() => void read(), POLL_MS)
    return () => {
      current = false
      clearInterval(timer)
    }
  }, [wanted])

  return waiting
}
