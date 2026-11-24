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
// The transport calls that matter for ordering: 'watch' and 'edit', in the order they happened.
const order = vi.hoisted(() => [] as string[])

const fake = fakeTransport({ files: {}, paths: {} as AppPaths })
const unwatched = vi.hoisted(() => ({ count: 0 }))

vi.mock('../transport/index.ts', () => ({
  transport: {
    ...fake,
    watchNoteRun: (run: string, onLine: (line: string) => void) => {
      order.push('watch')
      const unwatch = fake.watchNoteRun(run, onLine)
      return () => {
        unwatched.count += 1
        unwatch()
      }
    },
    editNote: (request: EditNoteRequest) => {
      order.push('edit')
      return new Promise<NoteEdit>((resolve, reject) => runs.push({ request, resolve, reject }))
    },
  },
}))

const { dismissNoteEdit, noteEditOf, onNoteEditChange, startNoteEdit, stopNoteEdit } =
  await import('./note-edits.ts')

const A = 'designs/a.md'
const B = 'designs/b.md'
const edit: NoteEdit = { before: 'old\n', after: 'new\n', touched: [] }

// Lets the run's promise settle and its handlers run.
const settled = () => new Promise((resolve) => setTimeout(resolve, 0))

const noRun = { run: null, startedAt: null, harness: null, stopping: false, lines: [] }
const idle = { working: false, edit: null, failure: null, ...noRun }

beforeEach(async () => {
  for (const run of runs.splice(0)) run.reject(new Error('reset'))
  await settled()
  dismissNoteEdit(A)
  dismissNoteEdit(B)
  order.length = 0
  unwatched.count = 0
  fake.stoppedRuns.length = 0
})

describe('the run of a note edit', () => {
  it('is working while the agent has not answered, and passes the request on', () => {
    expect(noteEditOf(A)).toEqual(idle)
    expect(startNoteEdit(A, { path: A, prompt: 'Tick it.', harness: 'Claude' })).toBe(true)
    const state = noteEditOf(A)
    expect(state).toMatchObject({ working: true, edit: null, failure: null, harness: 'Claude' })
    expect(state.stopping).toBe(false)
    expect(state.lines).toEqual([])
    expect(typeof state.startedAt).toBe('number')
    expect(runs.map((r) => r.request)).toEqual([
      { path: A, prompt: 'Tick it.', harness: 'Claude', run: state.run },
    ])
  })

  it('keeps what the change did, and tells onDone it went well', async () => {
    const done = vi.fn()
    startNoteEdit(A, { path: A, prompt: 'p' }, done)
    runs[0]?.resolve(edit)
    await settled()
    expect(noteEditOf(A)).toEqual({ ...idle, edit })
    expect(done).toHaveBeenCalledWith(true)
  })

  it('keeps the failure without the "Error: " prefix, and tells onDone it failed', async () => {
    const done = vi.fn()
    startNoteEdit(A, { path: A, prompt: 'p' }, done)
    runs[0]?.reject(new Error('the agent left the note unchanged'))
    await settled()
    expect(noteEditOf(A)).toEqual({ ...idle, failure: 'the agent left the note unchanged' })
    expect(done).toHaveBeenCalledWith(false)
  })

  it('refuses a second start on the same note while one is in progress', async () => {
    expect(startNoteEdit(A, { path: A, prompt: 'first' })).toBe(true)
    expect(startNoteEdit(A, { path: A, prompt: 'second' })).toBe(false)
    expect(runs).toHaveLength(1)
    runs[0]?.resolve(edit)
    await settled()
    expect(startNoteEdit(A, { path: A, prompt: 'third' })).toBe(true)
    expect(noteEditOf(A).working).toBe(true)
  })

  it('keeps two notes apart', async () => {
    expect(startNoteEdit(A, { path: A, prompt: 'a' })).toBe(true)
    expect(startNoteEdit(B, { path: B, prompt: 'b' })).toBe(true)
    runs[1]?.resolve(edit)
    await settled()
    expect(noteEditOf(A).working).toBe(true)
    expect(noteEditOf(B)).toEqual({ ...idle, edit })
  })

  it('forgets a result when dismissed, but not a run in progress', async () => {
    startNoteEdit(A, { path: A, prompt: 'p' })
    dismissNoteEdit(A)
    expect(noteEditOf(A).working).toBe(true)
    runs[0]?.resolve(edit)
    await settled()
    dismissNoteEdit(A)
    expect(noteEditOf(A)).toEqual(idle)
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

describe('the progress of a note edit run', () => {
  it('watches the run before it sends the request, and the request carries the run id', () => {
    startNoteEdit(A, { path: A, prompt: 'p' })
    expect(order).toEqual(['watch', 'edit'])
    expect(runs[0]?.request.run).toBe(noteEditOf(A).run)
    expect(noteEditOf(A).run).toMatch(/^[A-Za-z0-9_-]{1,64}$/)
  })

  it('appends the published lines, and ends the watch with the run', async () => {
    startNoteEdit(A, { path: A, prompt: 'p' })
    const run = noteEditOf(A).run!
    fake.emitRunLine(run, 'one')
    fake.emitRunLine(run, 'two')
    expect(noteEditOf(A).lines).toEqual(['one', 'two'])
    expect(unwatched.count).toBe(0)
    runs[0]?.resolve(edit)
    await settled()
    expect(unwatched.count).toBe(1)
    expect(noteEditOf(A).lines).toEqual([])
    fake.emitRunLine(run, 'late')
    expect(noteEditOf(A).lines).toEqual([])
  })

  it('stops the run with its id and says it is stopping, once', () => {
    startNoteEdit(A, { path: A, prompt: 'p' })
    const run = noteEditOf(A).run!
    stopNoteEdit(A)
    stopNoteEdit(A)
    expect(fake.stoppedRuns).toEqual([run])
    expect(noteEditOf(A).stopping).toBe(true)
    expect(noteEditOf(A).working).toBe(true)
  })

  it('does nothing to stop a note that has no run', () => {
    stopNoteEdit(A)
    expect(fake.stoppedRuns).toEqual([])
    expect(noteEditOf(A)).toEqual(idle)
  })

  it('shows the failure of a stopped run', async () => {
    startNoteEdit(A, { path: A, prompt: 'p' })
    stopNoteEdit(A)
    runs[0]?.reject(new Error('The run was stopped and the note was not changed.'))
    await settled()
    expect(noteEditOf(A)).toEqual({
      ...idle,
      failure: 'The run was stopped and the note was not changed.',
    })
  })

  it('does not start a second run on the same note, nor watch for it', () => {
    startNoteEdit(A, { path: A, prompt: 'first' })
    expect(startNoteEdit(A, { path: A, prompt: 'second' })).toBe(false)
    expect(order).toEqual(['watch', 'edit'])
  })
})
