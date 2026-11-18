import { useEffect, useRef } from 'react'
import type { WatchPlace } from '../../shared/transport.ts'
import { transport } from '../transport/index.ts'

// Calls `onChange` when something under the place changed, for as long as the component shows.
export function useWatch(place: WatchPlace, onChange: () => void): void {
  const latest = useRef(onChange)
  useEffect(() => {
    latest.current = onChange
  })
  useEffect(() => transport.watch(place, () => latest.current()), [place])
}
