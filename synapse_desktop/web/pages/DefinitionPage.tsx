import { Fragment, useCallback } from 'react'
import { describeDefinition, valueLabel, type DefinitionInfo } from '../domain/definition-info.ts'
import { buildReferenceIndex, usedBy } from '../domain/references.ts'
import { listSkillFiles, parseSkillMeta } from '../domain/skills.ts'
import { transport } from '../transport/index.ts'
import { DEFINITION_LABELS, type DefinitionKind, type Page } from '../state/state.ts'
import { useLoad } from '../state/useLoad.ts'

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

const loadIndex = () => buildReferenceIndex(transport)

// The attributes of a system or an agent as they are written, and the definitions that use it,
// as the CLI describes it.
function DefinitionDetails({
  kind,
  name,
  onOpen,
}: {
  kind: 'system' | 'agent'
  name: string
  onOpen: (page: Page) => void
}) {
  const load = useCallback(() => describeDefinition(transport, name), [name])
  const { state } = useLoad(load)
  if (state.status === 'loading') return <p className="muted">Reading the definition…</p>
  if (state.status === 'failed') return <p role="alert">Could not describe it: {state.error}</p>
  return <DefinitionFacts kind={kind} info={state.data} onOpen={onOpen} />
}

function DefinitionFacts({
  kind,
  info,
  onOpen,
}: {
  kind: 'system' | 'agent'
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
            {kind === 'system' ? 'No pipeline' : 'No pipeline or system'} uses this{' '}
            {DEFINITION_LABELS[kind].singular}.
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

// The steps of the pipelines that use a skill.
function UsedBy({
  kind,
  name,
  onOpen,
}: {
  kind: 'skill'
  name: string
  onOpen: (page: Page) => void
}) {
  const { state } = useLoad(loadIndex)
  return (
    <section className="card" aria-label="Used by">
      <h2 className="card-title">Used by</h2>
      {state.status === 'loading' && <p className="muted">Looking through the pipelines…</p>}
      {state.status === 'failed' && <p role="alert">Could not look: {state.error}</p>}
      {state.status === 'ready' && (
        <UsedByList kind={kind} name={name} index={state.data} onOpen={onOpen} />
      )}
    </section>
  )
}

function UsedByList({
  kind,
  name,
  index,
  onOpen,
}: {
  kind: 'skill'
  name: string
  index: Awaited<ReturnType<typeof buildReferenceIndex>>
  onOpen: (page: Page) => void
}) {
  const users = usedBy(index, kind, name)
  return (
    <>
      {users.length === 0 && (
        <p className="muted">No pipeline uses this {DEFINITION_LABELS[kind].singular}.</p>
      )}
      <ul className="used-by">
        {users.map((user) => {
          const pipeline = index.pipelines.find((p) => p.name === user.pipeline)
          return (
            <li key={`${user.pipeline}:${user.step}`}>
              {pipeline === undefined ? (
                <span className="mono">{user.pipeline}</span>
              ) : (
                <button
                  className="link mono"
                  onClick={() =>
                    onOpen({
                      kind: 'definition',
                      definition: 'pipeline',
                      name: pipeline.name,
                      path: pipeline.path,
                    })
                  }
                >
                  {user.pipeline}
                </button>
              )}
              <span className="muted"> · step {user.step}</span>
            </li>
          )
        })}
      </ul>
      {index.unreadable.length > 0 && (
        <p className="muted small">
          Not counted, because they cannot be described: {index.unreadable.join(', ')}.
        </p>
      )}
    </>
  )
}

// What a skill says about itself and what is in its directory.
function SkillCard({ path }: { path: string }) {
  const load = useCallback(async () => {
    const [text, files] = await Promise.all([
      transport.readText(path),
      listSkillFiles(transport, path),
    ])
    return { meta: parseSkillMeta(text), files }
  }, [path])
  const { state } = useLoad(load)
  if (state.status !== 'ready') return null
  const { meta, files } = state.data
  return (
    <section className="card" aria-label="Skill">
      <h2 className="card-title">Skill</h2>
      <dl className="facts">
        <dt>Description</dt>
        <dd>{meta.description ?? <span className="muted">none in its frontmatter</span>}</dd>
        <dt>Files</dt>
        <dd className="mono">{files.join('  ')}</dd>
      </dl>
    </section>
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
  return (
    <div className="page">
      <div className="page-head">
        <div>
          <p className="eyebrow">{DEFINITION_LABELS[definition].singular}</p>
          <h1 className="page-title">{name}</h1>
        </div>
        <button className="secondary" onClick={onEdit}>
          Edit
        </button>
      </div>
      {definition === 'skill' && <SkillCard path={path} />}
      {definition === 'skill' && <UsedBy kind={definition} name={name} onOpen={onOpen} />}
      {(definition === 'system' || definition === 'agent') && (
        <DefinitionDetails kind={definition} name={name} onOpen={onOpen} />
      )}
      <SourceCard path={path} />
    </div>
  )
}
