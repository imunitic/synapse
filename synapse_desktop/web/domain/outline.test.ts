import { describe, expect, it } from 'vitest'
import { fakeTransport } from './fake-transport.ts'
import { noteOutline, outlineTree, parseDocMap } from './outline.ts'

const SAMPLE = [
  'heading\tTarget',
  'heading\tTarget::Evidence',
  'heading\tTarget::Evidence::Detail',
  'heading\tTarget::Fix',
  'block\tTarget::Fix::0',
  'frontmatter\ttitle',
  'frontmatter\ttags',
  '',
].join('\n')

const paths = { definitionDirs: [], skillsDir: null, recordsDir: null }

describe('parseDocMap', () => {
  it('keeps the heading lines in order with their title and depth', () => {
    expect(parseDocMap(SAMPLE)).toEqual([
      { path: 'Target', title: 'Target', depth: 1 },
      { path: 'Target::Evidence', title: 'Evidence', depth: 2 },
      { path: 'Target::Evidence::Detail', title: 'Detail', depth: 3 },
      { path: 'Target::Fix', title: 'Fix', depth: 2 },
    ])
  })

  it('gives nothing for empty output', () => {
    expect(parseDocMap('')).toEqual([])
    expect(parseDocMap('\n\n')).toEqual([])
  })

  it('keeps a title with spaces whole', () => {
    expect(parseDocMap('heading\tA note::Alternatives considered here\n')).toEqual([
      {
        path: 'A note::Alternatives considered here',
        title: 'Alternatives considered here',
        depth: 2,
      },
    ])
  })
})

describe('outlineTree', () => {
  it('nests a heading under the heading whose path is its prefix', () => {
    const tree = outlineTree(
      parseDocMap('heading\tA\nheading\tA::B\nheading\tA::B::C\nheading\tA::D\n'),
    )
    expect(tree).toHaveLength(1)
    const [a] = tree
    expect(a?.heading.path).toBe('A')
    expect(a?.children.map((c) => c.heading.path)).toEqual(['A::B', 'A::D'])
    expect(a?.children[0]?.children.map((c) => c.heading.path)).toEqual(['A::B::C'])
    expect(a?.children[1]?.children).toEqual([])
  })

  it('puts a heading without a parent heading at the top', () => {
    const tree = outlineTree(parseDocMap('heading\tA::B\nheading\tC\n'))
    expect(tree.map((n) => n.heading.path)).toEqual(['A::B', 'C'])
  })
})

describe('noteOutline', () => {
  it('runs vault-doc-map for the note and parses its headings', async () => {
    const calls: (readonly string[])[] = []
    const transport = fakeTransport({
      files: {},
      paths,
      cli: (_binary, args) => {
        calls.push(args)
        return { code: 0, stdout: SAMPLE, stderr: '' }
      },
    })
    const headings = await noteOutline(transport, 'designs/a.md')
    expect(calls).toEqual([['vault-doc-map', 'designs/a.md']])
    expect(headings.map((h) => h.title)).toEqual(['Target', 'Evidence', 'Detail', 'Fix'])
  })

  it('throws the error of a failed run', async () => {
    const transport = fakeTransport({
      files: {},
      paths,
      cli: () => ({ code: 1, stdout: '', stderr: 'no such note\n' }),
    })
    await expect(noteOutline(transport, 'x.md')).rejects.toThrow('no such note')
  })
})
