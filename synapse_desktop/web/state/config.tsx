// The app's settings, loaded once from the server and shared with every page.

import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import type { AppConfig } from '../../shared/transport.ts'
import { transport } from '../transport/index.ts'

export type ConfigState =
  | { status: 'loading' }
  | { status: 'ready'; config: AppConfig }
  | { status: 'failed'; error: string }

interface ConfigApi {
  state: ConfigState
  save: (patch: Partial<AppConfig>) => Promise<void>
}

const ConfigContext = createContext<ConfigApi | null>(null)

export function ConfigProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<ConfigState>({ status: 'loading' })

  useEffect(() => {
    transport
      .getConfig()
      .then((config) => setState({ status: 'ready', config }))
      .catch((error: unknown) => setState({ status: 'failed', error: String(error) }))
  }, [])

  async function save(patch: Partial<AppConfig>): Promise<void> {
    const config = await transport.setConfig(patch)
    setState({ status: 'ready', config })
  }

  return <ConfigContext value={{ state, save }}>{children}</ConfigContext>
}

export function useConfig(): ConfigApi {
  const api = useContext(ConfigContext)
  if (api === null) throw new Error('useConfig needs a ConfigProvider')
  return api
}
