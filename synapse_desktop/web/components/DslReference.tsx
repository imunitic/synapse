import type { ReactNode } from 'react'
import {
  attributesFor,
  DSL_RULES,
  DSL_SHAPES,
  type DslKind,
  type DslWhere,
} from '../domain/dsl-reference.ts'

// A sentence with its `code` in the type of code.
function withCode(text: string): ReactNode[] {
  return text.split('`').map((part, i) => (i % 2 === 1 ? <code key={i}>{part}</code> : part))
}

const ON: Record<DslWhere, string> = {
  step: 'step',
  edge: 'edge',
  system: 'system',
  agent: 'agent',
}

// What to know to write a definition by hand, kept closed until it is wanted: its shape, the
// attributes it may carry and the rules it is held to.
export function DslReference({ kind }: { kind: DslKind }) {
  const attributes = attributesFor(kind)
  return (
    <details className="convention dsl-reference" data-kind={kind}>
      <summary>
        <span className="convention-title">Language reference</span>
        <span className="muted small convention-about">
          The shape, the attributes and the rules for writing a {kind} by hand.
        </span>
      </summary>
      <div className="convention-body">
        <h3 className="card-title">Shape</h3>
        <pre className="mono small dsl-shape" aria-label={`A ${kind}`}>
          {DSL_SHAPES[kind]}
        </pre>
        <h3 className="card-title">Attributes</h3>
        <table className="dsl-table" aria-label="Attributes">
          <thead>
            <tr>
              <th scope="col">Attribute</th>
              {kind === 'pipeline' && <th scope="col">On</th>}
              <th scope="col">Value</th>
              <th scope="col">Meaning</th>
            </tr>
          </thead>
          <tbody>
            {attributes.map((a) => (
              <tr key={a.name}>
                <th scope="row" className="mono">
                  {a.name}
                </th>
                {kind === 'pipeline' && <td>{a.on.map((w) => ON[w]).join(', ')}</td>}
                <td>{a.value}</td>
                <td>{a.meaning}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <h3 className="card-title">Rules</h3>
        <ul className="dsl-rules">
          {DSL_RULES[kind].map((rule) => (
            <li key={rule}>{withCode(rule)}</li>
          ))}
        </ul>
      </div>
    </details>
  )
}
