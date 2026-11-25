import { useCallback, useState } from 'react'
import { UsagePanel } from '../components/UsagePanel.tsx'
import { ageText, describe, dot, figureText, shownInBar } from '../domain/usage.ts'
import { useConfig } from '../state/config.tsx'
import { useUsage } from '../state/useUsage.ts'

export function StatusBar() {
  const { state } = useConfig()
  const workDir =
    state.status === 'ready'
      ? (state.config.workDir ?? 'none')
      : state.status === 'failed'
        ? 'unavailable'
        : '…'
  const { event, now } = useUsage()
  const [open, setOpen] = useState(false)
  const close = useCallback(() => setOpen(false), [])
  const readings = event?.readings ?? []
  const shown = readings.filter(shownInBar)

  return (
    <footer className="statusbar">
      <span className="mono">work dir: {workDir}</span>
      {/* No `mono` class here: the docs screenshots select `.statusbar .mono`. */}
      <div className="statusbar-usage">
        {shown.map((reading) => (
          <button
            key={reading.harness}
            type="button"
            className="usage-item"
            aria-label={describe(reading, now)}
            aria-expanded={open}
            title={
              reading.observedAt === null ? undefined : `Read ${ageText(reading.observedAt, now)}`
            }
            onClick={() => setOpen((was) => !was)}
          >
            <span className={`usage-dot usage-dot-${dot(reading, now)}`} aria-hidden="true" />
            {reading.harness} {figureText(reading, now)}
          </button>
        ))}
        {open && readings.length > 0 && (
          <UsagePanel readings={readings} now={now} onClose={close} />
        )}
      </div>
    </footer>
  )
}
