import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { AppPaths, EditNoteRequest, NoteEdit } from '../../shared/transport.ts'
import { fakeTransport } from '../domain/fake-transport.ts'

// Each run the stubbed editNote was asked for, with how to end it.
interface Pending {
  request: EditNoteRequest
  resolve: (edit: NoteEdit) => void
  reject: (error: Error) => void
}
const runs = vi.hoisted(() => [] as Pending[])

vi.mock('../transport/index.ts', () => ({
  transport: {
    ...fakeTransport({ files: {}, paths: {} as AppPaths }),
    editNote: (request: EditNoteRequest) =>
      new Promise<NoteEdit>((resolve, reject) => runs.push({ request, resolve, reject })),
  },
}))

const { dismissNoteEdit, noteEditOf, onNoteEditChange, startNoteEdit } =
  await import('./note-edits.ts')

const A = 'designs/a.md'
const B = 'designs/b.md'
const edit: NoteEdit = { before: 'old\n', after: 'new\n', touched: [] }

// Lets the run's promise settle and its handlers run.
const settled = () => new Promise((resolve) => setTimeout(resolve, 0))

beforeEach(async () => {
  for (const run of runs.splice(0)) run.reject(new Error('reset'))
  await settled()
  dismissNoteEdit(A)
  dismissNoteEdit(B)
})

describe('the run of a note edit', () => {
  it('is working while the agent has not answered, and passes the request on', () => {
    expect(noteEditOf(A)).toEqual({ working: false, edit: null, failure: null })
    expect(startNoteEdit(A, { path: A, prompt: 'Tick it.', harness: 'Claude' })).toBe(true)
    expect(noteEditOf(A)).toEqual({ working: true, edit: null, failure: null })
    expect(runs.map((r) => r.request)).toEqual([{ path: A, prompt: 'Tick it.', harness: 'Claude' }])
  })

  it('keeps what the change did, and tells onDone it went well', async () => {
    const done = vi.fn()
    startNoteEdit(A, { path: A, prompt: 'p' }, done)
    runs[0]?.resolve(edit)
    await settled()
    expect(noteEditOf(A)).toEqual({ working: false, edit, failure: null })
    expect(done).toHaveBeenCalledWith(true)
  })

  it('keeps the failure without the "Error: " prefix, and tells onDone it failed', async () => {
    const done = vi.fn()
    startNoteEdit(A, { path: A, prompt: 'p' }, done)
    runs[0]?.reject(new Error('the agent left the note unchanged'))
    await settled()
    expect(noteEditOf(A)).toEqual({
      working: false,
      edit: null,
      failure: 'the agent left the note unchanged',
    })
    expect(done).toHaveBeenCalledWith(false)
  })

  it('refuses a second start on the same note while one is in progress', async () => {
    expect(startNoteEdit(A, { path: A, prompt: 'first' })).toBe(true)
    expect(startNoteEdit(A, { path: A, prompt: 'second' })).toBe(false)
    expect(runs).toHaveLength(1)
    runs[0]?.resolve(edit)
    await settled()
    expect(startNoteEdit(A, { path: A, prompt: 'third' })).toBe(true)
    expect(noteEditOf(A)).toEqual({ working: true, edit: null, failure: null })
  })

  it('keeps two notes apart', async () => {
    expect(startNoteEdit(A, { path: A, prompt: 'a' })).toBe(true)
    expect(startNoteEdit(B, { path: B, prompt: 'b' })).toBe(true)
    runs[1]?.resolve(edit)
    await settled()
    expect(noteEditOf(A).working).toBe(true)
    expect(noteEditOf(B)).toEqual({ working: false, edit, failure: null })
  })

  it('forgets a result when dismissed, but not a run in progress', async () => {
    startNoteEdit(A, { path: A, prompt: 'p' })
    dismissNoteEdit(A)
    expect(noteEditOf(A).working).toBe(true)
    runs[0]?.resolve(edit)
    await settled()
    dismissNoteEdit(A)
    expect(noteEditOf(A)).toEqual({ working: false, edit: null, failure: null })
  })

  it('tells listeners when a run starts and ends, until they stop', async () => {
    const listener = vi.fn()
    const stop = onNoteEditChange(listener)
    startNoteEdit(A, { path: A, prompt: 'p' })
    runs[0]?.resolve(edit)
    await settled()
    expect(listener).toHaveBeenCalledTimes(2)
    stop()
    dismissNoteEdit(A)
    expect(listener).toHaveBeenCalledTimes(2)
  })
})
