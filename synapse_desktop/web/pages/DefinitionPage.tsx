import { Fragment, useCallback } from 'react'
import { CodeEditor } from '../components/CodeEditor.tsx'
import { describeDefinition, valueLabel, type DefinitionInfo } from '../domain/definition-info.ts'
import { transport } from '../transport/index.ts'
import { DEFINITION_LABELS, type DefinitionKind, type Page } from '../state/state.ts'
import { useLoad, type LoadState } from '../state/useLoad.ts'

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
      {state.status === 'ready' && (
        <CodeEditor initial={state.data} label="Source text" language="synapse" readOnly />
      )}
    </section>
  )
}

type DescribedKind = 'system' | 'agent' | 'prompt'

// The text of a definition's `Description`, or null when it has none or it is empty.
function descriptionOf(info: DefinitionInfo | null): string | null {
  const value = info?.attributes.find((a) => a.name === 'Description')?.value
  return typeof value === 'string' && value !== '' ? value : null
}

// The attributes of a system, an agent or a prompt as they are written, and the definitions that
// use it, as the CLI describes it.
function DefinitionDetails({
  kind,
  state,
  onOpen,
}: {
  kind: DescribedKind
  state: LoadState<DefinitionInfo | null>
  onOpen: (page: Page) => void
}) {
  if (state.status === 'loading') return <p className="muted">Reading the definition…</p>
  if (state.status === 'failed') return <p role="alert">Could not describe it: {state.error}</p>
  if (state.data === null) return null
  return <DefinitionFacts kind={kind} info={state.data} onOpen={onOpen} />
}

function DefinitionFacts({
  kind,
  info,
  onOpen,
}: {
  kind: DescribedKind
  info: DefinitionInfo
  onOpen: (page: Page) => void
}) {
  return (
    <>
      <section className="card" aria-label="Attributes">
        <h2 className="card-title">Attributes</h2>
        {info.attributes.length === 0 && <p className="muted">It sets none.</p>}
        <dl className="facts">
          {info.attributes.map((attribute) => (
            <Fragment key={attribute.name}>
              <dt>{attribute.name}</dt>
              <dd className="mono prompt">{valueLabel(attribute.value)}</dd>
            </Fragment>
          ))}
        </dl>
      </section>
      <section className="card" aria-label="Used by">
        <h2 className="card-title">Used by</h2>
        {info.used_by.length === 0 && (
          <p className="muted">
            {kind === 'system'
              ? 'No pipeline'
              : kind === 'agent'
                ? 'No pipeline or system'
                : 'No pipeline, system or agent'}{' '}
            uses this {DEFINITION_LABELS[kind].singular}.
          </p>
        )}
        <ul className="used-by">
          {info.used_by.map((user) => (
            <li key={`${user.kind}:${user.name}`}>
              <button
                className="link mono"
                onClick={() =>
                  onOpen({
                    kind: 'definition',
                    definition: user.kind,
                    name: user.name,
                    path: user.file,
                  })
                }
              >
                {user.name}
              </button>
              <span className="muted">
                {' '}
                · {user.kind}
                {user.steps.length > 0 &&
                  ` · ${user.steps.length === 1 ? 'step' : 'steps'} ${user.steps.join(', ')}`}
              </span>
            </li>
          ))}
        </ul>
      </section>
    </>
  )
}

export function DefinitionPage({
  definition,
  name,
  path,
  onOpen,
  onEdit,
}: {
  definition: DefinitionKind
  name: string
  path: string
  onOpen: (page: Page) => void
  onEdit: () => void
}) {
  const described = definition === 'pipeline' ? null : definition
  const load = useCallback(
    () =>
      described === null
        ? Promise.resolve(null)
        : describeDefinition(transport, name).then((info): DefinitionInfo | null => info),
    [described, name],
  )
  const { state } = useLoad(load)
  const description = state.status === 'ready' ? descriptionOf(state.data) : null
  return (
    <div className="page">
      <div className="page-head">
        <div>
          <p className="eyebrow">{DEFINITION_LABELS[definition].singular}</p>
          <h1 className="page-title">{name}</h1>
          {description !== null && <p className="muted">{description}</p>}
        </div>
        <button className="secondary" onClick={onEdit}>
          Edit
        </button>
      </div>
      {described !== null && <DefinitionDetails kind={described} state={state} onOpen={onOpen} />}
      <SourceCard path={path} />
    </div>
  )
}
