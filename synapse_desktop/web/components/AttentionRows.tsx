import type { AttentionItem, AttentionTarget } from '../domain/attention.ts'
import { remember } from '../pages/graph/namespace.ts'
import type { Page } from '../state/state.ts'

// The page an item of the attention lists leads to.
export function pageOf(target: AttentionTarget): Page {
  switch (target.kind) {
    case 'settings':
      return { kind: 'settings', section: target.section }
    case 'execution':
      return { kind: 'execution', id: target.id }
    case 'note':
      return { kind: 'note', path: target.path }
    case 'graph':
      remember(target.namespace)
      return { kind: 'graph' }
  }
}

// One thing that needs a look: its id and title, what is to be said of it, and a click that
// opens what it is about.
export function ItemRow({ item, onOpen }: { item: AttentionItem; onOpen: (page: Page) => void }) {
  const body = (
    <>
      <span className="attention-label">
        {item.id !== null && <span className="note-id">{item.id}</span>}
        {item.label}
      </span>
      {item.detail !== null && <span className="muted small attention-detail">{item.detail}</span>}
    </>
  )
  return (
    <li>
      {item.target === null ? (
        <div className="attention-item">{body}</div>
      ) : (
        <button
          className="attention-item attention-link"
          onClick={() => onOpen(pageOf(item.target as AttentionTarget))}
        >
          {body}
        </button>
      )}
    </li>
  )
}
