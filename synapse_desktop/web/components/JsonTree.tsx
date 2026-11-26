// A JSON value as a tree whose objects and arrays fold, with a button that copies the whole value.

import { useState } from 'react'
import { startsOpen } from '../domain/visit-outputs.ts'

type Branch = { kind: 'object' | 'array'; entries: [string, unknown][] }

function branchOf(value: unknown): Branch | null {
  if (Array.isArray(value)) return { kind: 'array', entries: value.map((v, i) => [String(i), v]) }
  if (typeof value === 'object' && value !== null)
    return { kind: 'object', entries: Object.entries(value) }
  return null
}

function Scalar({ value }: { value: unknown }) {
  const text = value === undefined ? 'undefined' : JSON.stringify(value)
  return <span className={`json-value json-${value === null ? 'null' : typeof value}`}>{text}</span>
}

function Node({ name, value, depth }: { name: string | null; value: unknown; depth: number }) {
  const branch = branchOf(value)
  const [open, setOpen] = useState(() =>
    branch === null ? false : startsOpen(depth, branch.entries.length),
  )
  const key = name !== null && <span className="json-key">{name}: </span>
  if (branch === null) {
    return (
      <div className="json-row">
        {key}
        <Scalar value={value} />
      </div>
    )
  }
  const [start, end] = branch.kind === 'array' ? ['[', ']'] : ['{', '}']
  return (
    <div className="json-branch">
      <button className="json-row json-toggle" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="json-arrow" aria-hidden="true">
          {open ? '▾' : '▸'}
        </span>
        {key}
        <span className="muted">{open ? start : `${start} ${branch.entries.length} ${end}`}</span>
      </button>
      {open && (
        <div className="json-children">
          {branch.entries.map(([childName, child]) => (
            <Node key={childName} name={childName} value={child} depth={depth + 1} />
          ))}
          <div className="json-row muted">{end}</div>
        </div>
      )}
    </div>
  )
}

export function JsonTree({ value }: { value: unknown }) {
  const [said, setSaid] = useState<string | null>(null)
  function copy() {
    navigator.clipboard
      .writeText(JSON.stringify(value, null, 2))
      .then(() => setSaid('Copied.'))
      .catch(() => setSaid('Could not copy.'))
  }
  return (
    <div className="json-tree">
      <div className="json-actions">
        <button className="secondary" onClick={copy}>
          Copy JSON
        </button>
        {said !== null && <span className="muted small">{said}</span>}
      </div>
      <div className="mono">
        <Node name={null} value={value} depth={0} />
      </div>
    </div>
  )
}
