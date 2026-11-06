import { useEffect, useState } from 'react'
import type { AppConfig } from '../shared/transport.ts'
import { transport } from './transport/index.ts'

type Load =
  { kind: 'loading' } | { kind: 'ready'; config: AppConfig } | { kind: 'failed'; error: string }

// A first screen that proves the page, the proxy and the server work together.
export function App() {
  const [load, setLoad] = useState<Load>({ kind: 'loading' })

  useEffect(() => {
    transport
      .getConfig()
      .then((config) => setLoad({ kind: 'ready', config }))
      .catch((error: unknown) => setLoad({ kind: 'failed', error: String(error) }))
  }, [])

  return (
    <main>
      <h1>Synapse Desktop</h1>
      {load.kind === 'loading' && <p>Loading…</p>}
      {load.kind === 'failed' && <p role="alert">The server did not answer: {load.error}</p>}
      {load.kind === 'ready' && <p>Work directory: {load.config.workDir ?? 'not set'}</p>}
    </main>
  )
}
