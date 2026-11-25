import { useEffect, useRef } from 'react'
import type { UsageReading } from '../../shared/usage.ts'
import { ageText, percentNow, shownInBar } from '../domain/usage.ts'

const STATE_WORDS: Record<UsageReading['state'], string> = {
  ok: 'up to date',
  stale: 'showing older figures',
  'not-signed-in': 'not signed in',
  unavailable: 'unavailable',
  'not-installed': 'not installed',
}

function resetText(resetsAt: string | null): string {
  if (resetsAt === null) return ''
  const reset = new Date(resetsAt)
  if (Number.isNaN(reset.getTime())) return ''
  return `resets ${reset.toLocaleString(undefined, {
    weekday: 'short',
    hour: 'numeric',
    minute: '2-digit',
  })}`
}

function ReadingSection({ reading, now }: { reading: UsageReading; now: Date }) {
  const age = reading.observedAt === null ? '' : ageText(reading.observedAt, now)
  return (
    <section className="usage-harness" aria-label={reading.harness}>
      <h3>
        {reading.harness}
        <span className="usage-state">{STATE_WORDS[reading.state]}</span>
      </h3>
      {reading.windows.length > 0 && (
        <ul className="usage-windows">
          {reading.windows.map((window) => (
            <li key={window.name}>
              <span className="usage-window-name">{window.name}</span>
              <span className="usage-window-percent">{Math.round(percentNow(window, now))}%</span>
              <span className="usage-window-reset">{resetText(window.resetsAt)}</span>
            </li>
          ))}
        </ul>
      )}
      {reading.spend !== null && (
        <p className="usage-spend">
          ${reading.spend.amount.toFixed(2)} spent{' '}
          {reading.spend.period === 'session' ? 'this session' : 'today'}
        </p>
      )}
      {age !== '' && <p className="usage-age">Read {age}</p>}
      {reading.reason !== null && (!shownInBar(reading) || reading.state === 'stale') && (
        <p className="usage-reason">{reading.reason}</p>
      )}
    </section>
  )
}

// Every harness's windows, spend and state, opened from a usage item in the status bar. Escape
// and a click outside close it.
export function UsagePanel({
  readings,
  now,
  onClose,
}: {
  readings: readonly UsageReading[]
  now: Date
  onClose: () => void
}) {
  const panel = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const keys = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    const pointer = (event: PointerEvent) => {
      const target = event.target as Node
      if (panel.current?.contains(target)) return
      // A click on a usage item toggles the panel itself.
      if (target instanceof Element && target.closest('.usage-item') !== null) return
      onClose()
    }
    document.addEventListener('keydown', keys)
    document.addEventListener('pointerdown', pointer)
    return () => {
      document.removeEventListener('keydown', keys)
      document.removeEventListener('pointerdown', pointer)
    }
  }, [onClose])

  return (
    <div className="usage-panel" role="dialog" aria-label="Harness usage" ref={panel}>
      {readings.map((reading) => (
        <ReadingSection key={reading.harness} reading={reading} now={now} />
      ))}
    </div>
  )
}
