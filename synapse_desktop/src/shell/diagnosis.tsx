// What `synapse doctor` says of the setup, loaded once from the server and shared with every
// page: the Home card shows what needs doing, and the pages that choose a harness hold back
// the ones that are not installed.

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import type { Diagnosis, Harness } from '../../shared/transport.ts'
import { effectiveHarness, harnessAvailability, type Availability } from '../domain/diagnosis.ts'
import { transport } from '../transport/index.ts'
import { useConfig } from './config.tsx'
import { TERMINAL_LABELS } from './state.ts'

export type DiagnosisState =
  { status: 'loading' } | { status: 'ready'; data: Diagnosis } | { status: 'failed'; error: string }

interface DiagnosisApi {
  state: DiagnosisState
  // Whether it is being looked at again, while the last answer stays.
  checking: boolean
  recheck: () => void
  // The warnings put aside, by the key of the check.
  dismissed: ReadonlySet<string>
  dismiss: (key: string) => void
  restore: () => void
}

const DiagnosisContext = createContext<DiagnosisApi | null>(null)

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

  const api = useMemo<DiagnosisApi>(
    () => ({
      state,
      checking,
      recheck: () => void check(),
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
    [state, checking, check, dismissed],
  )
  return <DiagnosisContext value={api}>{children}</DiagnosisContext>
}

export function useDiagnosis(): DiagnosisApi {
  const api = useContext(DiagnosisContext)
  if (api === null) throw new Error('useDiagnosis needs a DiagnosisProvider')
  return api
}

export interface Harnesses {
  availability: Record<Harness, Availability>
  // Whether the harness is known not to be there.
  isMissing: (harness: Harness) => boolean
  // Why it cannot be used, or null.
  reason: (harness: Harness) => string | null
  // The harness to use when none is asked for: the default, unless it is not there.
  defaultHarness: Harness
}

// Which harnesses can be used, from the one check the app makes. Until the check has
// answered, and when it could not, every harness can be.
export function useHarnesses(): Harnesses {
  const { state } = useDiagnosis()
  const { state: config } = useConfig()
  const chosen = config.status === 'ready' ? config.config.defaultHarness : null
  const diagnosis = state.status === 'ready' ? state.data : null
  return useMemo(() => {
    const availability = harnessAvailability(diagnosis)
    return {
      availability,
      isMissing: (harness) => availability[harness] === 'missing',
      reason: (harness) =>
        availability[harness] === 'missing'
          ? `${TERMINAL_LABELS[harness]} was not found on PATH`
          : null,
      defaultHarness: effectiveHarness(chosen, availability),
    }
  }, [diagnosis, chosen])
}
