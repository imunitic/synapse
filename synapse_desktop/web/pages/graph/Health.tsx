import { useCallback, useState } from 'react'
import { nodeNotePath } from '../../domain/graph-search.ts'
import {
  findingsOf,
  groupFindings,
  mergeReasons,
  nodesNeedingAttention,
  type NodeFindings,
  type Reason as ReasonText,
} from '../../domain/graph-health.ts'
import type { GraphCheck, GraphHealth } from '../../../shared/transport.ts'
import { transport } from '../../transport/index.ts'
import { useConfig } from '../../state/config.tsx'
import { type Page } from '../../state/state.ts'
import { useLoad } from '../../state/useLoad.ts'

type CheckKey = keyof GraphHealth

const CHECKS: { key: CheckKey; title: string; about: string }[] = [
  {
    key: 'stale',
    title: 'Stale nodes',
    about: 'Their files no longer match what they were written from.',
  },
  { key: 'drift', title: 'Drift', about: 'What changed since the commit each node was built at.' },
  {
    key: 'grounding',
    title: 'Not grounded',
    about: 'Their evidence no longer matches the files.',
  },
]

// One reason a node was found, with the files it lists kept closed.
function Reason({ reason: { text, items } }: { reason: ReasonText }) {
  return (
    <>
      <span className="muted small attention-detail">{text}</span>
      {items.length > 0 && (
        <details className="reason-files">
          <summary className="muted small">Show the {items.length} files</summary>
          <ul className="mono small">
            {items.map((file) => (
              <li key={file}>{file}</li>
            ))}
          </ul>
        </details>
      )}
    </>
  )
}

// A node with everything a check found about it, which opens the node. The repository is not a
// node and does not open.
function NodeEntry({
  namespace,
  group,
  onOpen,
}: {
  namespace: string
  group: NodeFindings
  onOpen: (page: Page) => void
}) {
  const repo = group.node === '(repo)'
  const name = repo ? 'The repository' : group.node
  return (
    <>
      {repo ? (
        <div className="attention-item">
          <span className="attention-label">{name}</span>
        </div>
      ) : (
        <button
          className="attention-item attention-link"
          onClick={() => onOpen({ kind: 'note', path: nodeNotePath(namespace, group.node) })}
        >
          <span className="attention-label">{name}</span>
        </button>
      )}
      <div className="finding-reasons">
        {mergeReasons(group.reasons).map((reason) => (
          <Reason key={reason.text} reason={reason} />
        ))}
      </div>
    </>
  )
}

// The count a check is shown by: the nodes it found something about, and how many findings those
// come to when they are more.
// Only a check that could not run is marked: a count of findings is information, and not an alarm.
function summary(check: GraphCheck): { value: string; note: string; failed: boolean } {
  if (!check.ok) return { value: '—', note: 'could not run', failed: true }
  const findings = findingsOf(check)
  const nodes = groupFindings(findings).length
  return {
    value: String(nodes),
    note: nodes === 0 ? 'none' : findings.length === nodes ? '' : `${findings.length} findings`,
    failed: false,
  }
}

// A check as a row that opens to what it found, as the files of the conventions are.
function CheckSection({
  id,
  title,
  about,
  check,
  open,
  onToggle,
  namespace,
  onOpen,
}: {
  id: string
  title: string
  about: string
  check: GraphCheck
  open: boolean
  onToggle: (open: boolean) => void
  namespace: string
  onOpen: (page: Page) => void
}) {
  const groups = groupFindings(findingsOf(check))
  return (
    <details
      id={id}
      className="convention"
      open={open}
      onToggle={(event) => onToggle(event.currentTarget.open)}
    >
      <summary>
        <span className="convention-title">{title}</span>
        <span className="muted small convention-about">{about}</span>
        <span className="convention-count">{check.ok ? groups.length : '—'}</span>
      </summary>
      {open && (
        <div className="convention-body" role="region" aria-label={title}>
          {!check.ok && <p role="alert">Could not run: {check.error}</p>}
          {check.ok && groups.length === 0 && <p className="muted">None.</p>}
          <ul className="attention-list">
            {groups.map((group) => (
              <li key={group.node}>
                <NodeEntry namespace={namespace} group={group} onOpen={onOpen} />
              </li>
            ))}
          </ul>
        </div>
      )}
    </details>
  )
}

// How a graph stands against the repository saved for it: a tile for each check, with its count,
// and the findings behind it when the tile is opened.
export function Health({ namespace, onOpen }: { namespace: string; onOpen: (page: Page) => void }) {
  const { state: config } = useConfig()
  const saved = config.status === 'ready' ? (config.config.graphRepos[namespace] ?? null) : null
  // The checks that are open. None are, so that the page is the summary until one is asked for.
  const [open, setOpen] = useState<ReadonlySet<CheckKey>>(new Set())
  // Read again when a folder is saved, since the checks need one.
  const load = useCallback(
    () =>
      saved === null
        ? Promise.reject(new Error('no repository'))
        : transport.graphHealth(namespace),
    [namespace, saved],
  )
  const { state, reload } = useLoad(load)
  if (saved === null) {
    return (
      <p className="muted">
        Save the folder of the repository above to check this graph against it.
      </p>
    )
  }
  if (state.status === 'loading')
    return <p className="muted">Checking the graph against the files…</p>
  if (state.status === 'failed') return <p role="alert">Could not check: {state.error}</p>
  const attention = nodesNeedingAttention(state.data)

  // A check is put open or shut by its tile or by its row, which are the same thing.
  function set(key: CheckKey, wanted: boolean) {
    setOpen((now) => {
      if (now.has(key) === wanted) return now
      const next = new Set(now)
      if (wanted) next.add(key)
      else next.delete(key)
      return next
    })
  }

  return (
    <>
      <div className="row">
        <p className="muted">
          {attention.length === 0
            ? 'No node needs attention.'
            : `${attention.length} ${attention.length === 1 ? 'node needs' : 'nodes need'} attention.`}
        </p>
        <button className="link" onClick={reload}>
          Check again
        </button>
      </div>
      <div className="tiles health-tiles" role="group" aria-label="Checks">
        {CHECKS.map(({ key, title }) => {
          const { value, note, failed } = summary(state.data[key])
          const shown = open.has(key)
          return (
            <button
              key={key}
              className="tile tile-button"
              data-tone={failed ? 'bad' : undefined}
              aria-expanded={shown}
              aria-controls={`health-${key}`}
              onClick={() => set(key, !shown)}
            >
              <span className="tile-value">{value}</span>
              <span className="tile-label">{title}</span>
              <span className="tile-label">{note}</span>
            </button>
          )
        })}
      </div>
      <div className="convention-cards">
        {CHECKS.map(({ key, title, about }) => (
          <CheckSection
            key={key}
            id={`health-${key}`}
            title={title}
            about={about}
            check={state.data[key]}
            open={open.has(key)}
            onToggle={(now) => set(key, now)}
            namespace={namespace}
            onOpen={onOpen}
          />
        ))}
      </div>
    </>
  )
}
