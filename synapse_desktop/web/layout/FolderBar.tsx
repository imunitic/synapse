import { useState } from 'react'
import type { FormEvent, KeyboardEvent } from 'react'
import { baseName } from '../domain/changes.ts'
import { PathInput } from '../components/PathInput.tsx'
import { CloseIcon, PlusIcon } from '../components/icons.tsx'

// What the folder bar shows and does. Each of the callbacks that take a typed path answers what is
// wrong with it, or null when it was done.
export interface FolderBarProps {
  // The folder the changes are of, and where its HEAD is when that is known.
  folder: string
  head: string | null
  // Folders looked at before, offered while typing.
  known: string[]
  // The other repositories shown next to the folder, in the order they were added.
  added: string[]
  // Moves to another folder; null where the folder cannot change, as for a run.
  onChange: ((typed: string) => Promise<string | null>) | null
  onAdd: (typed: string) => Promise<string | null>
  onRemove: (folder: string) => void
}

// The box is right-to-left so that a long path loses its start, not its end; the path inside keeps
// its own left-to-right order, or the leading slash would be drawn at the end.
function FolderPath({ path }: { path: string }) {
  return (
    <span className="folder-path">
      <bdi dir="ltr">{path}</bdi>
    </span>
  )
}

// The folder a terminal session's or a run's changes are of, and the other repositories shown next
// to it. A session's folder can be moved to another one: an agent that works in a worktree of its
// own is looked at by typing that folder's path. The + adds a repository, typed the same way.
export function FolderBar({
  folder,
  head,
  known,
  added,
  onChange,
  onAdd,
  onRemove,
}: FolderBarProps) {
  const [typing, setTyping] = useState<'change' | 'add' | null>(null)
  const [text, setText] = useState('')
  const [error, setError] = useState<string | null>(null)

  const open = (what: 'change' | 'add') => {
    setText(what === 'change' ? folder : '')
    setError(null)
    setTyping(what)
  }
  const close = () => {
    setTyping(null)
    setError(null)
  }
  const submit = (event: FormEvent) => {
    event.preventDefault()
    const act = typing === 'change' ? onChange : onAdd
    if (act === null) return
    void act(text).then((problem) => {
      if (problem === null) close()
      else setError(problem)
    })
  }
  const keys = (event: KeyboardEvent) => {
    if (event.key === 'Escape') close()
  }
  const offered = known.filter((one) => one !== folder && !added.includes(one))

  return (
    <div className="folder-bar">
      {typing !== null ? (
        <form onSubmit={submit} onKeyDown={keys}>
          <PathInput
            className="folder-input"
            aria-label={typing === 'change' ? 'Folder to look at' : 'Repository to add'}
            placeholder="Absolute path of a folder in a git repository"
            list="folder-bar-known"
            value={text}
            autoFocus
            onChange={setText}
            onFocus={(event) => event.target.select()}
          />
          <datalist id="folder-bar-known">
            {offered.map((one) => (
              <option key={one} value={one} />
            ))}
          </datalist>
          {error !== null && (
            <p className="folder-error" role="alert">
              {error}
            </p>
          )}
        </form>
      ) : (
        <>
          {onChange === null ? (
            <span className="folder-current" title={folder}>
              <FolderPath path={folder} />
              {head !== null && <span className="folder-head">{head}</span>}
            </span>
          ) : (
            <button
              className="folder-current"
              title={`${folder}: click to look at another folder`}
              aria-label={`Folder: ${folder}. Change it`}
              onClick={() => open('change')}
            >
              <FolderPath path={folder} />
              {head !== null && <span className="folder-head">{head}</span>}
            </button>
          )}
          <button
            className="icon-button"
            aria-label="Add a repository"
            title="Add a repository"
            onClick={() => open('add')}
          >
            <PlusIcon />
          </button>
        </>
      )}
      {typing === null && added.length > 0 && (
        <ul className="folder-added" aria-label="Repositories added">
          {added.map((one) => (
            <li key={one} className="folder-current" title={one}>
              <FolderPath path={baseName(one)} />
              <button
                className="icon-button"
                aria-label={`Remove ${one}`}
                title={`Remove ${one}`}
                onClick={() => onRemove(one)}
              >
                <CloseIcon />
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
