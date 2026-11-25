import { useEffect, useState } from 'react'
import type { UsageEvent } from '../../shared/usage.ts'
import { transport } from '../transport/index.ts'

// Once a minute the time moves on, so the ages and the greying of old figures follow.
const TICK_MS = 60_000

function isVisible(): boolean {
  return document.visibilityState === 'visible'
}

// The last usage event and the time to judge it by. Watched only while the window shows, so the
// host does not read the harnesses for a hidden window.
export function useUsage(): { event: UsageEvent | null; now: Date } {
  const [event, setEvent] = useState<UsageEvent | null>(null)
  const [now, setNow] = useState(() => new Date())

  useEffect(() => {
    let stop: (() => void) | null = null
    const follow = () => {
      if (isVisible() && stop === null) {
        stop = transport.watchUsage((next) => {
          setEvent(next)
          setNow(new Date())
        })
      } else if (!isVisible() && stop !== null) {
        stop()
        stop = null
      }
    }
    follow()
    document.addEventListener('visibilitychange', follow)
    return () => {
      document.removeEventListener('visibilitychange', follow)
      stop?.()
    }
  }, [])

  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), TICK_MS)
    return () => clearInterval(timer)
  }, [])

  return { event, now }
}
