import { useCallback, useState, type Dispatch } from 'react'
import {
  buildTree,
  listNotes,
  searchNotes,
  titleOf,
  type SearchHit,
  type TreeFolder,
} from '../domain/notes.ts'
import { transport } from '../transport/index.ts'
import { ChevronIcon, FolderIcon, NoteIcon, PlusIcon, RefreshIcon } from './icons.tsx'
import type { Action, ShellState } from './state.ts'
import { useLoad } from './useLoad.ts'

function Folder({
  folder,
  depth,
  open,
  toggle,
  active,
  onOpen,
}: {
  folder: TreeFolder
  depth: number
  open: ReadonlySet<string>
  toggle: (path: string) => void
  active: string | null
  onOpen: (path: string) => void
}) {
  const indent = { paddingLeft: 8 + depth * 14 }
  return (
    <>
      {folder.folders.map((child) => (
        <div key={child.path}>
          <button
            className="tree-item tree-folder"
            style={indent}
            aria-expanded={open.has(child.path)}
            onClick={() => toggle(child.path)}
          >
            <ChevronIcon open={open.has(child.path)} />
            <FolderIcon open={open.has(child.path)} />
            <span className="tree-name">{child.name}</span>
          </button>
          {open.has(child.path) && (
            <Folder
              folder={child}
              depth={depth + 1}
              open={open}
              toggle={toggle}
              active={active}
              onOpen={onOpen}
            />
          )}
        </div>
      ))}
      {folder.notes.map((note) => (
        <button
          key={note.path}
          className="tree-item"
          style={indent}
          aria-current={active === note.path ? 'true' : undefined}
          onClick={() => onOpen(note.path)}
        >
          <span className="tree-spacer" aria-hidden="true" />
          <NoteIcon />
          <span className="tree-name">{note.name}</span>
        </button>
      ))}
    </>
  )
}

// The vault's notes as a tree of folders, and a search over their text.
export function VaultPanel({ state, dispatch }: { state: ShellState; dispatch: Dispatch<Action> }) {
  const loadAll = useCallback(() => listNotes(transport), [])
  // Read again when a note has been written.
  const { state: notes, reload } = useLoad(loadAll, undefined, state.reloadToken)
  const [open, setOpen] = useState<ReadonlySet<string>>(new Set())
  const [draft, setDraft] = useState('')
  const [query, setQuery] = useState('')
  const [hits, setHits] = useState<
    | { status: 'idle' }
    | { status: 'busy' }
    | { status: 'ready'; data: SearchHit[] }
    | { status: 'failed'; error: string }
  >({ status: 'idle' })
  const active = state.activeId?.startsWith('note:') ? state.activeId.slice(5) : null

  function openNote(path: string) {
    dispatch({ type: 'openPage', page: { kind: 'note', path } })
  }

  function toggle(path: string) {
    setOpen((current) => {
      const next = new Set(current)
      if (!next.delete(path)) next.add(path)
      return next
    })
  }

  async function search(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    const text = draft.trim()
    setQuery(text)
    if (text === '') {
      setHits({ status: 'idle' })
      return
    }
    setHits({ status: 'busy' })
    try {
      setHits({ status: 'ready', data: await searchNotes(transport, text) })
    } catch (error) {
      setHits({ status: 'failed', error: String(error) })
    }
  }

  const tree = notes.status === 'ready' ? buildTree(notes.data) : null
  return (
    <>
      <div className="panel-header">
        <h2 className="panel-title">Vault</h2>
        <div className="row">
          <button className="icon-button" aria-label="Refresh the notes" onClick={reload}>
            <RefreshIcon />
          </button>
          <button
            className="icon-button"
            aria-label="New note"
            onClick={() => dispatch({ type: 'openPage', page: { kind: 'new-note' } })}
          >
            <PlusIcon />
          </button>
        </div>
      </div>
      <form className="panel-search" role="search" onSubmit={(event) => void search(event)}>
        <input
          type="search"
          aria-label="Search the notes"
          placeholder="Search the notes"
          value={draft}
          onChange={(event) => {
            setDraft(event.target.value)
            if (event.target.value.trim() === '') {
              setQuery('')
              setHits({ status: 'idle' })
            }
          }}
        />
      </form>
      {query !== '' ? (
        <div className="list" aria-label="Search results">
          {hits.status === 'busy' && <p className="panel-empty">Searching…</p>}
          {hits.status === 'failed' && (
            <p className="panel-empty" role="alert">
              {hits.error}
            </p>
          )}
          {hits.status === 'ready' && hits.data.length === 0 && (
            <p className="panel-empty">No note has those words.</p>
          )}
          {hits.status === 'ready' &&
            hits.data.map((hit) => (
              <button
                key={hit.path}
                className="list-item"
                aria-current={active === hit.path ? 'true' : undefined}
                onClick={() => openNote(hit.path)}
              >
                <span className="list-name">{titleOf(hit.path)}</span>
                <span className="muted small">{hit.path}</span>
              </button>
            ))}
        </div>
      ) : (
        <div className="tree" aria-label="Notes">
          {notes.status === 'loading' && <p className="panel-empty">Loading…</p>}
          {notes.status === 'failed' && (
            <p className="panel-empty" role="alert">
              {notes.error.includes('no vault') ? 'No vault is chosen.' : notes.error}
            </p>
          )}
          {tree !== null && notes.status === 'ready' && notes.data.length === 0 && (
            <p className="panel-empty">The vault has no notes.</p>
          )}
          {tree !== null && (
            <Folder
              folder={tree}
              depth={0}
              open={open}
              toggle={toggle}
              active={active}
              onOpen={openNote}
            />
          )}
        </div>
      )}
    </>
  )
}
