import { useState } from 'react'
import { transport } from '../../transport/index.ts'
import { useConfig } from '../../state/config.tsx'
import { TERMINAL_LABELS, type TerminalKind, type TerminalTask } from '../../state/state.ts'
import { HarnessSelect, useHarness } from './harness.tsx'

// A graph that does not exist yet is built from a repository folder: the folder is
// checked for the namespace it is on, which is the graph's name, and an agent builds
// it with the first-build command in that folder.
export function NewGraph({
  existing,
  onSelect,
  onStartTask,
  onClose,
}: {
  existing: readonly string[]
  onSelect: (namespace: string) => void
  onStartTask: (kind: TerminalKind, cwd: string, task: TerminalTask) => void
  onClose: () => void
}) {
  const { state: config, save } = useConfig()
  const { harness, choose } = useHarness()
  const [draft, setDraft] = useState('')
  const [found, setFound] = useState<{ path: string; key: string } | null>(null)
  const [error, setError] = useState<string | null>(null)

  const close = onClose

  async function check(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    const path = draft.trim()
    if (path === '') return
    setFound(null)
    const result = await transport.checkGraphRepo(path).catch((e: unknown) => ({
      key: null,
      error: String(e),
    }))
    if (result.key === null) {
      setError(result.error ?? 'That folder has no namespace.')
      return
    }
    setError(null)
    setFound({ path, key: result.key })
  }

  async function build(path: string, key: string) {
    if (config.status !== 'ready') return
    try {
      await save({ graphRepos: { ...config.config.graphRepos, [key]: path } })
    } catch (e) {
      setError(`Not saved: ${String(e)}`)
      return
    }
    onStartTask(harness, path, 'init')
    close()
  }

  const exists = found !== null && existing.includes(found.key)
  return (
    <section className="card" aria-label="New graph">
      <h3 className="card-title">New graph</h3>
      <form className="row" onSubmit={(event) => void check(event)}>
        <input
          className="grow"
          aria-label="Folder of the repository to build from"
          placeholder="/path/to/the/repository"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
        <button className="secondary" type="submit" disabled={draft.trim() === ''}>
          Check
        </button>
        <button className="link" type="button" onClick={close}>
          Cancel
        </button>
      </form>
      {error !== null && <p role="alert">{error}</p>}
      {found !== null && exists && (
        <p>
          {found.key} already has a graph. Rebuild it from its Manage tab.{' '}
          <button
            className="link"
            onClick={() => {
              onSelect(found.key)
              close()
            }}
          >
            Open it
          </button>
        </p>
      )}
      {found !== null && !exists && (
        <div className="confirm" role="alertdialog" aria-label="Are you sure?">
          <p>
            <strong>Are you sure?</strong> This opens a session in {found.path} that builds the
            first graph of {found.key}. It takes a while, uses {TERMINAL_LABELS[harness]}'s credits
            and will ask you things.
          </p>
          <HarnessSelect label="Harness for the new graph" harness={harness} onChange={choose} />
          <div className="row">
            <button className="primary" onClick={() => void build(found.path, found.key)}>
              Yes, open {TERMINAL_LABELS[harness]}
            </button>
            <button className="secondary" onClick={close}>
              Cancel
            </button>
          </div>
        </div>
      )}
    </section>
  )
}
