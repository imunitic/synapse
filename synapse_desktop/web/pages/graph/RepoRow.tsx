import { useCallback, useState } from 'react'
import { transport } from '../../transport/index.ts'
import { useConfig } from '../../state/config.tsx'
import { useLoad } from '../../state/useLoad.ts'

// The folder of the repository a graph was built from, which its health is read
// against. The folder is checked when it is saved and shown with the branch it is
// on, since a checkout of another branch makes every node look stale.
export function RepoRow({ namespace }: { namespace: string }) {
  const { state: config, save } = useConfig()
  const saved = config.status === 'ready' ? (config.config.graphRepos[namespace] ?? null) : null
  const [draft, setDraft] = useState('')
  const [editing, setEditing] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const loadCheck = useCallback(
    () => (saved === null ? Promise.resolve(null) : transport.checkGraphRepo(saved)),
    [saved],
  )
  const { state: check } = useLoad(loadCheck)
  // Looked for when there is no folder, or the one saved is on another branch.
  const wrongBranch =
    check.status === 'ready' && check.data?.key != null && check.data.key !== namespace
  const looking = saved === null || wrongBranch
  const loadFound = useCallback(
    () => (looking ? transport.findGraphRepos(namespace) : Promise.resolve({ paths: [] })),
    [looking, namespace],
  )
  const { state: found } = useLoad(loadFound)
  const suggested =
    found.status === 'ready' ? found.data.paths.filter((path) => path !== saved) : []

  async function put(repos: Record<string, string>) {
    try {
      await save({ graphRepos: repos })
      setMessage(null)
      setEditing(false)
    } catch (error) {
      setMessage(`Not saved: ${String(error)}`)
    }
  }

  async function submit(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    const path = draft.trim()
    if (path === '' || config.status !== 'ready') return
    const result = await transport.checkGraphRepo(path).catch((error: unknown) => ({
      key: null,
      error: String(error),
    }))
    if (result.key === null) {
      setMessage(result.error ?? 'That folder has no namespace.')
      return
    }
    await put({ ...config.config.graphRepos, [namespace]: path })
  }

  if (config.status !== 'ready') return null
  const suggestions = suggested.length > 0 && (
    <div className="repo-suggest bar-note small" aria-label="Checkouts found">
      <span className="muted">
        {suggested.length === 1 ? 'A checkout' : 'Checkouts'} of {namespace} found:
      </span>
      {suggested.map((path) => (
        <span key={path} className="repo-suggestion">
          <span className="mono">{path}</span>
          <button
            className="link"
            onClick={() => void put({ ...config.config.graphRepos, [namespace]: path })}
          >
            Use it
          </button>
        </span>
      ))}
    </div>
  )
  if (saved !== null && !editing) {
    const other = wrongBranch
    return (
      <>
        <span className="muted small">Repository</span>
        <div className="repo-row" aria-label="Repository">
          <span className="mono small">{saved}</span>
          {check.status === 'ready' && check.data?.key != null && (
            <span className={other ? 'repo-warning small' : 'muted small'}>
              {other
                ? `is on ${check.data.key}, not ${namespace}, so every node may look stale`
                : `on ${check.data.key}`}
            </span>
          )}
          {check.status === 'ready' && check.data?.key == null && check.data?.error != null && (
            <span className="repo-warning small">{check.data.error}</span>
          )}
          <button
            className="link"
            onClick={() => {
              setDraft(saved)
              setEditing(true)
            }}
          >
            Change
          </button>
          <button
            className="link"
            onClick={() => {
              const rest = { ...config.config.graphRepos }
              delete rest[namespace]
              void put(rest)
            }}
          >
            Remove
          </button>
        </div>
        {suggestions}
      </>
    )
  }
  return (
    <>
      <span className="muted small">Repository</span>
      <form className="repo-row" aria-label="Repository" onSubmit={(event) => void submit(event)}>
        <input
          className="mono grow"
          aria-label="Repository folder"
          placeholder="/path/to/the/repository this graph was built from"
          value={draft}
          onChange={(event) => {
            setDraft(event.target.value)
            setMessage(null)
          }}
        />
        <button type="submit" className="secondary" disabled={draft.trim() === ''}>
          Save
        </button>
        {editing && (
          <button type="button" className="link" onClick={() => setEditing(false)}>
            Cancel
          </button>
        )}
        {message !== null && (
          <span role="alert" className="repo-warning small">
            {message}
          </span>
        )}
      </form>
      {suggestions}
    </>
  )
}
