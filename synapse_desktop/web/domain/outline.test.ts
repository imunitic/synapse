import { describe, expect, it } from 'vitest'
import { fakeTransport } from './fake-transport.ts'
import {
  duplicatePaths,
  noteOutline,
  outlineTree,
  pairHeadings,
  parseDocMap,
  visibleTitle,
} from './outline.ts'

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

describe('duplicate paths', () => {
  const twice = parseDocMap(
    'heading\tA\nheading\tA::Notes\nheading\tA::Notes::X\nheading\tA::Notes\n',
  )

  it('names a path two sibling headings share', () => {
    expect(duplicatePaths(twice)).toEqual(new Set(['A::Notes']))
    expect(duplicatePaths(parseDocMap(SAMPLE))).toEqual(new Set())
  })

  it('keeps both headings in the tree, a child under the earlier one', () => {
    const [a] = outlineTree(twice)
    expect(a?.children.map((c) => c.heading.path)).toEqual(['A::Notes', 'A::Notes'])
    expect(a?.children[0]?.children.map((c) => c.heading.path)).toEqual(['A::Notes::X'])
    expect(a?.children[1]?.children).toEqual([])
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

describe('pairHeadings', () => {
  const outline = parseDocMap(SAMPLE)

  it('pairs the rendered headings when the page strips the H1', () => {
    expect(pairHeadings(outline, ['Evidence', 'Detail', 'Fix'])).toEqual([
      'Target::Evidence',
      'Target::Evidence::Detail',
      'Target::Fix',
    ])
  })

  it('skips a doc-map heading that is not rendered', () => {
    const withCode = parseDocMap(
      'heading\tT\nheading\tT::A\nheading\tT::A::In code\nheading\tT::B\n',
    )
    expect(pairHeadings(withCode, ['A', 'B'])).toEqual(['T::A', 'T::B'])
  })

  it('leaves a rendered title without a doc-map heading unpaired', () => {
    expect(pairHeadings(outline, ['Evidence', 'Elsewhere', 'Fix'])).toEqual([
      'Target::Evidence',
      null,
      'Target::Fix',
    ])
  })

  it('pairs two headings with the same title in different sections in order', () => {
    const twice = parseDocMap(
      'heading\tT\nheading\tT::A\nheading\tT::A::Notes\nheading\tT::B\nheading\tT::B::Notes\n',
    )
    expect(pairHeadings(twice, ['A', 'Notes', 'B', 'Notes'])).toEqual([
      'T::A',
      'T::A::Notes',
      'T::B',
      'T::B::Notes',
    ])
  })

  it('gives nothing for no rendered headings', () => {
    expect(pairHeadings(outline, [])).toEqual([])
  })

  it('pairs a heading with inline code, whose doc-map title keeps the backticks', () => {
    const withCode = parseDocMap(
      'heading\tT\nheading\tT::Approach\nheading\tT::Approach::`synapse-query`: frozen surface\n',
    )
    expect(pairHeadings(withCode, ['Approach', 'synapse-query: frozen surface'])).toEqual([
      'T::Approach',
      'T::Approach::`synapse-query`: frozen surface',
    ])
  })

  it('pairs headings with emphasis, links, wikilinks and closing hashes', () => {
    const marked = parseDocMap(
      [
        'heading\tT',
        'heading\tT::An *em* and **strong** and _u_',
        'heading\tT::See [the docs](http://x.y) and [[Other note|alias]] and [[Plain]]',
        'heading\tT::Escaped \\* star',
        'heading\tT::a \\*b\\* c',
        'heading\tT::Trailing ##',
        '',
      ].join('\n'),
    )
    expect(
      pairHeadings(marked, [
        'An em and strong and u',
        'See the docs and alias and Plain',
        'Escaped * star',
        'a *b* c',
        'Trailing',
      ]),
    ).toEqual(marked.slice(1).map((h) => h.path))
  })

  it('pairs headings whose code span holds text that looks like markup', () => {
    const coded = parseDocMap(
      [
        'heading\tT',
        'heading\tT::`Vec<String>` layout',
        'heading\tT::The `<details>` element',
        'heading\tT::Link `[x](y)` kept',
        'heading\tT::Escape `a\\*b` kept',
        '',
      ].join('\n'),
    )
    expect(
      pairHeadings(coded, [
        'Vec<String> layout',
        'The <details> element',
        'Link [x](y) kept',
        'Escape a\\*b kept',
      ]),
    ).toEqual(coded.slice(1).map((h) => h.path))
  })
})

describe('visibleTitle', () => {
  it('reduces inline markdown to the text the page shows', () => {
    expect(visibleTitle('`synapse-query`: frozen')).toBe('synapse-query: frozen')
    expect(visibleTitle('An *em* and **strong** and _u_ and ~~gone~~')).toBe(
      'An em and strong and u and gone',
    )
    expect(visibleTitle('[the docs](http://x.y), [[Other note|alias]], [[Plain#Part]]')).toBe(
      'the docs, alias, Plain',
    )
    expect(visibleTitle('Escaped \\* star & <b>html</b> ##')).toBe('Escaped * star & html')
    expect(visibleTitle('a \\*b\\* c')).toBe('a *b* c')
    expect(visibleTitle('a \\_b\\_ \\~~c\\~~ \\[d\\](e)')).toBe('a _b_ ~~c~~ [d](e)')
  })

  it('keeps snake_case and the markdown inside a code span', () => {
    expect(visibleTitle('The snake_case_name')).toBe('The snake_case_name')
    expect(visibleTitle('Use `a *b* c`')).toBe('Use a *b* c')
  })
})
