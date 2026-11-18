// What `synapse doctor` says of the setup, shared with every page through a context, and the hooks
// that read it: the Home card shows what needs doing, and the pages that choose a harness hold back
// the ones that are not installed.

import { createContext, useContext, useMemo } from 'react'
import type { Diagnosis, Harness } from '../../shared/transport.ts'
import { effectiveHarness, harnessAvailability, type Availability } from '../domain/diagnosis.ts'
import { useConfig } from './config.tsx'
import { TERMINAL_LABELS } from './state.ts'

export type DiagnosisState =
  { status: 'loading' } | { status: 'ready'; data: Diagnosis } | { status: 'failed'; error: string }

export interface DiagnosisApi {
  state: DiagnosisState
  // Whether it is being looked at again, while the last answer stays.
  checking: boolean
  recheck: () => void
  // The warnings put aside, by the key of the check.
  dismissed: ReadonlySet<string>
  dismiss: (key: string) => void
  restore: () => void
}

// What DiagnosisProvider (its own file, so that a hot update cannot make a second context) supplies.
export const DiagnosisContext = createContext<DiagnosisApi | null>(null)

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
