import { describe, expect, it, vi } from 'vitest'
import { type NoteHeadings, noteHeadings, registerNoteHeadings } from './note-headings.ts'

function headings(): NoteHeadings {
  return { scrollTo: vi.fn(), comment: vi.fn() }
}

describe('note headings', () => {
  it('has nothing for a note that did not register', () => {
    expect(noteHeadings('designs/none.md')).toBeNull()
  })

  it('calls what the page registered', () => {
    const page = headings()
    const unregister = registerNoteHeadings('designs/a.md', page)
    noteHeadings('designs/a.md')?.scrollTo('A::Fix')
    noteHeadings('designs/a.md')?.comment('A::Fix')
    expect(page.scrollTo).toHaveBeenCalledWith('A::Fix')
    expect(page.comment).toHaveBeenCalledWith('A::Fix')
    unregister()
    expect(noteHeadings('designs/a.md')).toBeNull()
  })

  it('keeps two notes apart', () => {
    const a = headings()
    const b = headings()
    const offA = registerNoteHeadings('designs/a.md', a)
    const offB = registerNoteHeadings('designs/b.md', b)
    expect(noteHeadings('designs/a.md')).toBe(a)
    expect(noteHeadings('designs/b.md')).toBe(b)
    offA()
    offB()
  })

  it('unregisters only when still the registered one', () => {
    const first = headings()
    const second = headings()
    const offFirst = registerNoteHeadings('designs/a.md', first)
    const offSecond = registerNoteHeadings('designs/a.md', second)
    offFirst()
    expect(noteHeadings('designs/a.md')).toBe(second)
    offSecond()
    expect(noteHeadings('designs/a.md')).toBeNull()
  })
})
