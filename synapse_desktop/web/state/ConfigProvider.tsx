// Loads the app's settings once from the server and shares them through ConfigContext.

import { useEffect, useState, type ReactNode } from 'react'
import type { AppConfig } from '../../shared/transport.ts'
import { transport } from '../transport/index.ts'
import { ConfigContext, type ConfigState } from './config.tsx'

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
