import { useCallback, useEffect, useMemo, useState } from 'react'
import { readRunName } from '../domain/executions.ts'
import { transport } from '../transport/index.ts'
import { useWatch } from './useWatch.ts'

// The names of the runs among `ids` that have one, by id. Read again when something in the work
// directory changes, so a rename shows without the page being opened again.
export function useRunNames(ids: readonly string[]): ReadonlyMap<string, string> {
  const key = ids.join(',')
  const wanted = useMemo(() => (key === '' ? [] : key.split(',')), [key])
  const [names, setNames] = useState<ReadonlyMap<string, string>>(new Map())
  const [version, setVersion] = useState(0)
  const reread = useCallback(() => setVersion((v) => v + 1), [])
  useWatch('work', reread)

  useEffect(() => {
    if (wanted.length === 0) {
      setNames((now) => (now.size === 0 ? now : new Map()))
      return
    }
    let current = true
    void Promise.all(
      wanted.map(async (id) => [id, await readRunName(transport, id).catch(() => null)] as const),
    ).then((read) => {
      if (!current) return
      const found = new Map<string, string>()
      for (const [id, name] of read) if (name !== null) found.set(id, name)
      setNames((now) => (sameNames(now, found) ? now : found))
    })
    return () => {
      current = false
    }
  }, [wanted, version])

  return names
}

function sameNames(a: ReadonlyMap<string, string>, b: ReadonlyMap<string, string>): boolean {
  return a.size === b.size && [...a].every(([id, name]) => b.get(id) === name)
}
