import { useCallback } from 'react'
import { transport } from '../transport/index.ts'
import { DEFINITION_LABELS, type DefinitionKind } from './state.ts'
import { useLoad } from './useLoad.ts'

// A definition's file as it is on disk.
export function SourceCard({ path }: { path: string }) {
  const load = useCallback(() => transport.readText(path), [path])
  const { state } = useLoad(load)
  return (
    <section className="card" aria-label="Source">
      <h2 className="card-title">Source</h2>
      <p className="muted mono">{path}</p>
      {state.status === 'loading' && <p className="muted">Loading…</p>}
      {state.status === 'failed' && <p role="alert">Could not read the file: {state.error}</p>}
      {state.status === 'ready' && <pre className="source mono">{state.data}</pre>}
    </section>
  )
}

export function DefinitionPage({
  definition,
  name,
  path,
}: {
  definition: DefinitionKind
  name: string
  path: string
}) {
  return (
    <div className="page">
      <p className="eyebrow">{DEFINITION_LABELS[definition].singular}</p>
      <h1 className="page-title">{name}</h1>
      <SourceCard path={path} />
    </div>
  )
}
