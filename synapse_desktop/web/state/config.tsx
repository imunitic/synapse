// The app's settings, loaded once from the server and shared with every page: the context, and the
// hook that reads it.

import { createContext, useContext } from 'react'
import type { AppConfig } from '../../shared/transport.ts'

export type ConfigState =
  | { status: 'loading' }
  | { status: 'ready'; config: AppConfig }
  | { status: 'failed'; error: string }

export interface ConfigApi {
  state: ConfigState
  save: (patch: Partial<AppConfig>) => Promise<void>
}

// What ConfigProvider (its own file, so that a hot update cannot make a second context) supplies.
export const ConfigContext = createContext<ConfigApi | null>(null)

export function useConfig(): ConfigApi {
  const api = useContext(ConfigContext)
  if (api === null) throw new Error('useConfig needs a ConfigProvider')
  return api
}
