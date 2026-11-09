import { useCallback } from 'react'
import { listNodes, listUnassigned, nodeNotePath } from '../../domain/graph-search.ts'
import { transport } from '../../transport/index.ts'
import { type Page } from '../../state/state.ts'
import { useLoad } from '../../state/useLoad.ts'
import { MAX_ROWS } from './rows.ts'

export function Nodes({ namespace, onOpen }: { namespace: string; onOpen: (page: Page) => void }) {
  const loadNodes = useCallback(() => listNodes(transport, namespace), [namespace])
  const loadUnassigned = useCallback(() => listUnassigned(transport, namespace), [namespace])
  const { state: nodes } = useLoad(loadNodes)
  const { state: unassigned } = useLoad(loadUnassigned)

  return (
    <>
      {nodes.status === 'loading' && <p className="muted">Loading…</p>}
      {nodes.status === 'failed' && <p role="alert">{nodes.error}</p>}
      {nodes.status === 'ready' && (
        <section aria-label="Nodes">
          <h3 className="attention-title">
            Nodes<span className="count-pill">{nodes.data.length}</span>
          </h3>
          <ul className="attention-list">
            {nodes.data.map((node) => (
              <li key={node}>
                <button
                  className="attention-item attention-link"
                  onClick={() => onOpen({ kind: 'note', path: nodeNotePath(namespace, node) })}
                >
                  <span className="attention-label">{node.replace(/\.md$/, '')}</span>
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}
      {unassigned.status === 'ready' && unassigned.data.length > 0 && (
        <details className="card" aria-label="Unassigned files">
          <summary>
            {unassigned.data.length} {unassigned.data.length === 1 ? 'file is' : 'files are'}{' '}
            claimed by no node
          </summary>
          <ul className="hits">
            {unassigned.data.slice(0, MAX_ROWS).map((path) => (
              <li key={path} className="mono small">
                {path}
              </li>
            ))}
          </ul>
        </details>
      )}
    </>
  )
}
