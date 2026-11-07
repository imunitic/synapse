import { describe, expect, it } from 'vitest'
import type { CliResult, Transport } from '../../shared/transport.ts'
import {
  buildTree,
  linkifyWikilinks,
  listNotes,
  nameIndex,
  noteBacklinks,
  noteLinks,
  parseHits,
  parseNote,
  parseUpdated,
  recentlyUpdated,
  readNote,
  resolveLink,
  searchNotes,
  titleOf,
  wikilinkTarget,
  withoutTitleHeading,
} from './notes.ts'

function answering(answer: (args: string[]) => CliResult): {
  transport: Transport
  seen: string[][]
} {
  const seen: string[][] = []
  const transport = {
    cli: (_binary: string, args: string[]) => {
      seen.push(args)
      return Promise.resolve(answer(args))
    },
  } as unknown as Transport
  return { transport, seen }
}

const ok = (stdout: string): CliResult => ({ code: 0, stdout, stderr: '' })

describe('names and the tree', () => {
  it('name a note by its file without .md', () => {
    expect(titleOf('designs/p/Talk.md')).toBe('Talk')
    expect(titleOf('Index.md')).toBe('Index')
    expect(titleOf('designs/p/no extension')).toBe('no extension')
  })

  it('make folders of folders, sorted, folders first and the index before the notes', () => {
    const tree = buildTree([
      'tasks/p/B.md',
      'Index.md',
      'designs/p/Talk.md',
      'README.md',
      'tasks/p/A.md',
      'tasks/Loose.md',
      'zeta.md',
    ])
    expect(tree.folders.map((f) => f.name)).toEqual(['designs', 'tasks'])
    expect(tree.notes.map((n) => n.name)).toEqual(['Index', 'README', 'zeta'])
    const tasks = tree.folders[1]
    expect(tasks?.notes.map((n) => n.name)).toEqual(['Loose'])
    expect(tasks?.folders[0]).toMatchObject({ name: 'p', path: 'tasks/p' })
    expect(tasks?.folders[0]?.notes.map((n) => n.path)).toEqual(['tasks/p/A.md', 'tasks/p/B.md'])
  })
})

describe('reading from the vault', () => {
  it('lists the notes, one path to a line', async () => {
    const { transport, seen } = answering(() => ok('a.md\nb/c.md\n'))
    expect(await listNotes(transport)).toEqual(['a.md', 'b/c.md'])
    expect(seen[0]).toEqual(['vault-list'])
  })

  it('searches, best first, and skips rows that are not hits', async () => {
    expect(parseHits('a.md\t2.5\t1,2\nbad row\nb.md\t7\t3\n')).toEqual([
      { path: 'a.md', score: 2.5 },
      { path: 'b.md', score: 7 },
    ])
    const { transport, seen } = answering(() => ok('a.md\t2.5\t1\nb.md\t7\t3\n'))
    expect((await searchNotes(transport, 'two words')).map((h) => h.path)).toEqual(['b.md', 'a.md'])
    expect(seen[0]).toEqual(['vault-search-text', 'two words'])
  })

  it('reads the links of a note and the notes that link to it', async () => {
    const { transport } = answering((args) =>
      ok(args[0] === 'vault-links' ? 'x.md\ny.md\n' : 'z.md\t3\nw.md\n'),
    )
    expect(await noteLinks(transport, 'a.md')).toEqual(['x.md', 'y.md'])
    expect(await noteBacklinks(transport, 'a.md')).toEqual([
      { path: 'z.md', count: 3 },
      { path: 'w.md', count: 1 },
    ])
  })

  it('fail with the reason when the program does', async () => {
    const { transport } = answering(() => ({
      code: 1,
      stdout: '',
      stderr: 'synapse-vault: no vault\n',
    }))
    await expect(listNotes(transport)).rejects.toThrow('no vault')
    await expect(readNote(transport, 'a.md')).rejects.toThrow('no vault')
  })
})

describe('a note', () => {
  it('has its frontmatter and body apart, and takes its title from the frontmatter', () => {
    const note = parseNote(
      'tasks/p/Work.md',
      '---\ntitle: "A real title"\ntags:\n  - a\n  - b\nstatus: DONE\n---\n# Heading\n\nText\n',
    )
    expect(note.title).toBe('A real title')
    expect(note.frontmatter).toMatchObject({ status: 'DONE', tags: ['a', 'b'] })
    expect(note.body).toBe('# Heading\n\nText\n')
  })

  it('is all body, titled by its file, without frontmatter or with some that does not parse', () => {
    expect(parseNote('x/Plain.md', 'just text')).toMatchObject({
      title: 'Plain',
      frontmatter: null,
      body: 'just text',
    })
    const broken = parseNote('x/Broken.md', '---\nkey: [unclosed\n---\nbody')
    expect(broken.frontmatter).toBeNull()
    expect(broken.body).toContain('key: [unclosed')
    expect(parseNote('x/List.md', '---\n- a\n- b\n---\nbody').frontmatter).toBeNull()
  })

  it('is read with vault-read', async () => {
    const { transport, seen } = answering(() => ok('---\ntitle: T\n---\nbody\n'))
    expect((await readNote(transport, 'a/T.md')).title).toBe('T')
    expect(seen[0]).toEqual(['vault-read', 'a/T.md'])
  })
})

describe('wikilinks', () => {
  it('become links to the target, with their alias or name as the text, outside code', () => {
    expect(
      linkifyWikilinks('see [[Talk]] and [[Work|the work]] and [[Page#Part]] and [[A#B|c]]'),
    ).toBe(
      'see [Talk](wikilink:Talk) and [the work](wikilink:Work) and [Page](wikilink:Page) and [c](wikilink:A)',
    )
    expect(linkifyWikilinks('`[[Kept]]` and\n```\n[[Fenced]]\n```\nand [[Open]]')).toBe(
      '`[[Kept]]` and\n```\n[[Fenced]]\n```\nand [Open](wikilink:Open)',
    )
    expect(linkifyWikilinks('a name with a space [[Two Words]]')).toContain('wikilink:Two%20Words')
  })

  it('are read back from the link they became', () => {
    expect(wikilinkTarget('wikilink:Two%20Words')).toBe('Two Words')
    expect(wikilinkTarget('https://example.com')).toBeNull()
  })

  it('resolve to the note of that name, the one the note links to when two have it', () => {
    const index = nameIndex(['a/Same.md', 'b/Same.md', 'c/Other.md'])
    expect(resolveLink(index, 'Other', new Set())).toBe('c/Other.md')
    expect(resolveLink(index, 'Same', new Set())).toBe('a/Same.md')
    expect(resolveLink(index, 'Same', new Set(['b/Same.md']))).toBe('b/Same.md')
    expect(resolveLink(index, 'folder/Other.md', new Set())).toBe('c/Other.md')
    expect(resolveLink(index, 'Missing', new Set())).toBeNull()
  })
})

describe('the title heading', () => {
  it('is left out of the body when it says what the title says', () => {
    expect(withoutTitleHeading('# Talk\n\n## Status\nx\n', ['Talk'])).toBe('## Status\nx\n')
    expect(withoutTitleHeading('\n# Talk  \ntext', ['Other', 'Talk'])).toBe('text')
    expect(withoutTitleHeading('# Talk\n', ['Talk'])).toBe('')
  })

  it('is kept when it says something else, is not the first line or is a lower heading', () => {
    expect(withoutTitleHeading('# Another\n\ntext', ['Talk'])).toBe('# Another\n\ntext')
    expect(withoutTitleHeading('text\n# Talk\n', ['Talk'])).toBe('text\n# Talk\n')
    expect(withoutTitleHeading('## Talk\ntext', ['Talk'])).toBe('## Talk\ntext')
  })
})

describe('the notes updated last', () => {
  const rows =
    'a.md\tA\t2026-11-01T10:00:00+01:00\n' +
    'b.md\tB\t2026-11-07T10:00:00+01:00\n' +
    'c.md\t\t2026-11-05T10:00:00+01:00\n' +
    'd.md\tD\tnot a date\n' +
    'e.md\tE\n'

  it('are newest first by the date, titled by the file when they have no title, with no bad dates', () => {
    expect(parseUpdated(rows, 10)).toEqual([
      { path: 'b.md', title: 'B', updated: '2026-11-07T10:00:00+01:00' },
      { path: 'c.md', title: 'c', updated: '2026-11-05T10:00:00+01:00' },
      { path: 'a.md', title: 'A', updated: '2026-11-01T10:00:00+01:00' },
    ])
    expect(parseUpdated(rows, 2).map((n) => n.path)).toEqual(['b.md', 'c.md'])
  })

  it('are searched for with a rule on standard input', async () => {
    let seen: { args: string[]; stdin: string | undefined } | null = null
    const transport = {
      cli: (_binary: string, args: string[], options?: { stdin?: string }) => {
        seen = { args, stdin: options?.stdin }
        return Promise.resolve({ code: 0, stdout: rows, stderr: '' })
      },
    } as unknown as Transport
    expect((await recentlyUpdated(transport, 1))[0]?.path).toBe('b.md')
    expect(seen).toEqual({
      args: ['vault-search', '--fields', 'frontmatter.title,frontmatter.updated'],
      stdin: '{"var":"frontmatter.updated"}',
    })
    const failing = {
      cli: () =>
        Promise.resolve({ code: 1, stdout: '', stderr: 'synapse-vault-search: no vault\n' }),
    } as unknown as Transport
    await expect(recentlyUpdated(failing, 5)).rejects.toThrow('no vault')
  })
})
