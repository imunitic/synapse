import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { HostError } from '../shared/dispatch.ts'
import { createNoteRuns } from './note-runs.ts'

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

function collect() {
  const got: Array<[unknown, number | undefined]> = []
  return { got, push: (data: unknown, cursor?: number) => void got.push([data, cursor]) }
}

describe('note runs', () => {
  it('aborts the signal on stop, and stopped() is true only after a stop', () => {
    const runs = createNoteRuns()
    const handle = runs.start('a')
    expect(handle.stopped()).toBe(false)
    expect(handle.signal.aborted).toBe(false)
    runs.stop('a')
    expect(handle.signal.aborted).toBe(true)
    expect(handle.stopped()).toBe(true)
  })

  it('does nothing when an unknown id is stopped', () => {
    expect(() => createNoteRuns().stop('nope')).not.toThrow()
  })

  it('is not stopped when it only finished', () => {
    const runs = createNoteRuns()
    const handle = runs.start('a')
    handle.finish()
    runs.stop('a')
    expect(handle.stopped()).toBe(false)
  })

  it('gives a subscriber the lines from before and after it subscribed', () => {
    const runs = createNoteRuns()
    const handle = runs.start('a')
    handle.publish('one')
    const { got, push } = collect()
    runs.subscribe('a', undefined, push)
    handle.publish('two')
    expect(got).toEqual([
      [{ line: 'one' }, 0],
      [{ line: 'two' }, 1],
    ])
  })

  it('skips the lines the subscriber already has', () => {
    const runs = createNoteRuns()
    const handle = runs.start('a')
    handle.publish('one')
    handle.publish('two')
    handle.publish('three')
    const { got, push } = collect()
    runs.subscribe('a', 1, push)
    expect(got).toEqual([[{ line: 'three' }, 2]])
  })

  it('gives lines to a subscriber that came before the run started', () => {
    const runs = createNoteRuns()
    const { got, push } = collect()
    runs.subscribe('a', undefined, push)
    runs.start('a').publish('one')
    expect(got).toEqual([[{ line: 'one' }, 0]])
  })

  it('stops giving lines once the subscriber ended', () => {
    const runs = createNoteRuns()
    const handle = runs.start('a')
    const { got, push } = collect()
    const end = runs.subscribe('a', undefined, push)
    handle.publish('one')
    end()
    handle.publish('two')
    expect(got).toHaveLength(1)
  })

  it('drops the entry 60 seconds after it finished', () => {
    const runs = createNoteRuns()
    const handle = runs.start('a')
    handle.publish('one')
    handle.finish()
    vi.advanceTimersByTime(59_000)
    const early = collect()
    runs.subscribe('a', undefined, early.push)
    expect(early.got).toHaveLength(1)
    vi.advanceTimersByTime(1_000)
    const late = collect()
    runs.subscribe('a', undefined, late.push)
    expect(late.got).toHaveLength(0)
  })

  it('refuses a second start of a running id', () => {
    const runs = createNoteRuns()
    runs.start('a')
    expect(() => runs.start('a')).toThrow(HostError)
    try {
      runs.start('a')
    } catch (error) {
      expect((error as HostError).code).toBe('conflict')
    }
  })

  it('allows a start of an id whose run finished', () => {
    const runs = createNoteRuns()
    runs.start('a').finish()
    expect(() => runs.start('a')).not.toThrow()
  })
})
