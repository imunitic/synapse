// Loads what `synapse doctor` says once from the server and shares it through DiagnosisContext.

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { transport } from '../transport/index.ts'
import { DiagnosisContext, type DiagnosisApi, type DiagnosisState } from './diagnosis.tsx'

// What window focus asks again at most this often.
const FOCUS_RECHECK_MS = 5000

const DISMISSED_KEY = 'synapse-desktop.dismissed-findings'

// Kept for this browser. Storage may be missing or full; then a warning comes back.
function readDismissed(): Set<string> {
  try {
    const raw = localStorage.getItem(DISMISSED_KEY)
    const keys: unknown = raw === null ? [] : JSON.parse(raw)
    return new Set(Array.isArray(keys) ? keys.filter((k) => typeof k === 'string') : [])
  } catch {
    return new Set()
  }
}

function writeDismissed(keys: ReadonlySet<string>): void {
  try {
    localStorage.setItem(DISMISSED_KEY, JSON.stringify([...keys]))
  } catch {
    // Not kept.
  }
}

export function DiagnosisProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<DiagnosisState>({ status: 'loading' })
  const [checking, setChecking] = useState(false)
  const [dismissed, setDismissed] = useState(readDismissed)
  const lastAsked = useRef(0)

  const check = useCallback(async () => {
    lastAsked.current = Date.now()
    setChecking(true)
    try {
      setState({ status: 'ready', data: await transport.getDiagnosis() })
    } catch (error) {
      setState({ status: 'failed', error: String(error).replace(/^Error: /, '') })
    } finally {
      setChecking(false)
    }
  }, [])

  useEffect(() => {
    void check()
  }, [check])

  // Installing a program somewhere else and coming back is the usual way a finding goes away.
  useEffect(() => {
    const onFocus = () => {
      if (Date.now() - lastAsked.current >= FOCUS_RECHECK_MS) void check()
    }
    window.addEventListener('focus', onFocus)
    return () => window.removeEventListener('focus', onFocus)
  }, [check])

  const recheck = useCallback(() => void check(), [check])

  const api = useMemo<DiagnosisApi>(
    () => ({
      state,
      checking,
      recheck,
      dismissed,
      dismiss: (key) =>
        setDismissed((before) => {
          const next = new Set(before).add(key)
          writeDismissed(next)
          return next
        }),
      restore: () => {
        const none = new Set<string>()
        writeDismissed(none)
        setDismissed(none)
      },
    }),
    [state, checking, recheck, dismissed],
  )
  return <DiagnosisContext value={api}>{children}</DiagnosisContext>
}
