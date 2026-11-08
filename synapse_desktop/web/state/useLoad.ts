import { useCallback, useEffect, useState } from 'react'

export type LoadState<T> =
  { status: 'loading' } | { status: 'ready'; data: T } | { status: 'failed'; error: string }

// Runs `load` when the component appears and again on `reload`, or every
// `refreshMs` when given, and when `reloadKey` changes. `load` must be the same
// function on every render.
// A reload keeps the data on screen until the new data arrives.
export function useLoad<T>(
  load: () => Promise<T>,
  refreshMs?: number,
  reloadKey?: number,
): { state: LoadState<T>; reload: () => void } {
  const [state, setState] = useState<LoadState<T>>({ status: 'loading' })
  const [version, setVersion] = useState(0)

  useEffect(() => {
    let current = true
    load()
      .then((data) => current && setState({ status: 'ready', data }))
      .catch((error: unknown) => current && setState({ status: 'failed', error: String(error) }))
    return () => {
      current = false
    }
  }, [load, version, reloadKey])

  useEffect(() => {
    if (refreshMs === undefined) return
    const timer = setInterval(() => setVersion((v) => v + 1), refreshMs)
    return () => clearInterval(timer)
  }, [refreshMs])

  const reload = useCallback(() => setVersion((v) => v + 1), [])
  return { state, reload }
}
