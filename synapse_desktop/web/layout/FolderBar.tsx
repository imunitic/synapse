import { useEffect, useState } from 'react'
import type { FormEvent, KeyboardEvent } from 'react'
import { baselineOf, followFolder, onBaselineChange } from '../state/change-baselines.ts'
import { transport } from '../transport/index.ts'

// The folder a terminal session's changes and commits are of, with a way to move to another one: an
// agent that works in a worktree of its own is looked at by typing that folder's path.
export function FolderBar({ session }: { session: string }) {
  const [, setTick] = useState(0)
  useEffect(() => onBaselineChange(() => setTick((n) => n + 1)), [])
  const [typing, setTyping] = useState(false)
  const [text, setText] = useState('')
  const [error, setError] = useState<string | null>(null)
  const baseline = baselineOf(session)
  if (baseline === null) return null

  const open = () => {
    setText(baseline.folder)
    setError(null)
    setTyping(true)
  }
  const close = () => {
    setTyping(false)
    setError(null)
  }
  const submit = (event: FormEvent) => {
    event.preventDefault()
    void followFolder(transport, session, text).then((problem) => {
      if (problem === null) close()
      else setError(problem)
    })
  }
  const keys = (event: KeyboardEvent) => {
    if (event.key === 'Escape') close()
  }
  const others = Object.keys(baseline.others ?? {})

  return (
    <div className="folder-bar">
      {typing ? (
        <form onSubmit={submit} onKeyDown={keys}>
          <input
            className="folder-input"
            aria-label="Folder to look at"
            placeholder="Absolute path of a folder in a git repository"
            list="folder-bar-known"
            value={text}
            autoFocus
            spellCheck={false}
            onChange={(event) => setText(event.target.value)}
            onFocus={(event) => event.target.select()}
          />
          <datalist id="folder-bar-known">
            {others.map((folder) => (
              <option key={folder} value={folder} />
            ))}
          </datalist>
          {error !== null && (
            <p className="folder-error" role="alert">
              {error}
            </p>
          )}
        </form>
      ) : (
        <button
          className="folder-current"
          title={`${baseline.folder}: click to look at another folder`}
          aria-label={`Folder: ${baseline.folder}. Change it`}
          onClick={open}
        >
          <span className="folder-path">{baseline.folder}</span>
          {baseline.head !== undefined && baseline.head !== null && (
            <span className="folder-head">{baseline.head}</span>
          )}
        </button>
      )}
    </div>
  )
}
