import { describe, expect, it } from 'vitest'
import { noteSummary } from './note-summary.ts'

const NOW = new Date('2026-11-08T12:00:00Z')

describe('the summary of a note', () => {
  it('is its id, when it was updated and its tags', () => {
    expect(
      noteSummary(
        {
          schema: 'vault-note/v1',
          note_id: 'sb-242',
          updated: '2026-11-08T10:00:00Z',
          tags: ['synapse', 'dev-tooling'],
        },
        NOW,
      ),
    ).toEqual({
      id: 'sb-242',
      status: null,
      updated: '2 hours ago',
      tags: ['synapse', 'dev-tooling'],
    })
  })

  it('knows a task note by its task id, and has its status', () => {
    expect(
      noteSummary({ task_id: 'sb-239', note_id: 'sb-1', status: 'IN-PROGRESS' }, NOW),
    ).toMatchObject({ id: 'sb-239', status: 'IN-PROGRESS' })
  })

  it('has nothing for what is not there or not text', () => {
    expect(noteSummary(null, NOW)).toEqual({ id: null, status: null, updated: null, tags: [] })
    expect(noteSummary({ note_id: 7, updated: 'not a date', tags: 'x' }, NOW)).toEqual({
      id: null,
      status: null,
      updated: null,
      tags: [],
    })
    expect(noteSummary({ tags: ['a', 3, 'b'] }, NOW).tags).toEqual(['a', 'b'])
  })
})
