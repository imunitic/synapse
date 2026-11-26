import { describe, expect, it } from 'vitest'
import {
  sinceLabel,
  baseName,
  changeSet,
  defaultBase,
  folderOf,
  groupByFolder,
  groupTotals,
  pathMatches,
} from './changes.ts'

const PATCH = `diff --git a/src/a.txt b/src/a.txt
--- a/src/a.txt
+++ b/src/a.txt
@@ -1 +1,2 @@
 one
+two
diff --git a/blob.bin b/blob.bin
Binary files a/blob.bin and b/blob.bin differ
`

describe('changeSet', () => {
  it('has the files of the patch with their counts, and the new files as rows to open', () => {
    const { files, diffs } = changeSet(PATCH, [
      { path: 'src/new/b.txt', lines: 4 },
      { path: 'src/new/c.png', lines: null },
    ])
    expect(files).toEqual([
      {
        path: 'blob.bin',
        oldPath: null,
        status: 'modified',
        added: null,
        removed: null,
        binary: true,
        deferred: false,
      },
      {
        path: 'src/a.txt',
        oldPath: null,
        status: 'modified',
        added: 1,
        removed: 0,
        binary: false,
        deferred: false,
      },
      {
        path: 'src/new/b.txt',
        oldPath: null,
        status: 'added',
        added: 4,
        removed: 0,
        binary: false,
        deferred: true,
      },
      {
        path: 'src/new/c.png',
        oldPath: null,
        status: 'added',
        added: null,
        removed: null,
        binary: true,
        deferred: true,
      },
    ])
    // Only what the patch holds has a diff to show at once.
    expect([...diffs.keys()].sort()).toEqual(['blob.bin', 'src/a.txt'])
  })

  it('is empty when nothing changed', () => {
    expect(changeSet('', [])).toEqual({ files: [], diffs: new Map() })
  })
})

describe('the folders of the files', () => {
  it('are the part of a path before its last slash, and the name is what follows it', () => {
    expect(folderOf('a.txt')).toBe('')
    expect(folderOf('src/new/b.txt')).toBe('src/new')
    expect(baseName('src/new/b.txt')).toBe('b.txt')
    expect(baseName('a.txt')).toBe('a.txt')
  })

  it('group the files, those at the top first, a new folder as its files under its path', () => {
    const { files } = changeSet(PATCH, [
      { path: 'src/new/b.txt', lines: 1 },
      { path: 'src/new/d.txt', lines: 2 },
    ])
    expect(
      groupByFolder(files).map((g) => [g.folder, g.files.map((f) => baseName(f.path))]),
    ).toEqual([
      ['', ['blob.bin']],
      ['src', ['a.txt']],
      ['src/new', ['b.txt', 'd.txt']],
    ])
  })
})

describe('pathMatches', () => {
  it('is whether the whole path of a file ends with the path in the repository, at a folder', () => {
    expect(pathMatches('/work/widget/src/a.txt', 'src/a.txt')).toBe(true)
    expect(pathMatches('/work/widget/a.txt', 'a.txt')).toBe(true)
    expect(pathMatches('a.txt', 'a.txt')).toBe(true)
    expect(pathMatches('C:\\work\\widget\\src\\a.txt', 'src/a.txt')).toBe(true)
  })

  it('is not whether only the end of a name is the same', () => {
    expect(pathMatches('/work/widget/src/xa.txt', 'a.txt')).toBe(false)
    expect(pathMatches('/work/widget/src/a.txt', 'other/a.txt')).toBe(false)
  })
})

describe('defaultBase', () => {
  it('is the start of a session, and the last commit for one that continues another', () => {
    expect(defaultBase({})).toBe('start')
    expect(defaultBase({ resume: 'abc-123' })).toBe('commit')
  })
})

describe('sinceLabel', () => {
  it('names the branch only once the session has been on more than one', () => {
    expect(sinceLabel(null)).toBe('Since the session started')
    expect(sinceLabel({ head: 'main', switched: false })).toBe('Since the session started on main')
    expect(sinceLabel({ head: 'feature/x', switched: true })).toBe('Since switching to feature/x')
  })

  it('shortens a commit, for a detached HEAD', () => {
    expect(sinceLabel({ head: 'a'.repeat(40), switched: true })).toBe('Since switching to aaaaaaa')
  })
})

describe('groupTotals', () => {
  it('counts the files and sums their lines, a binary file as a file with no lines', () => {
    const set = changeSet(PATCH, [
      { path: 'src/new/b.txt', lines: 4 },
      { path: 'src/new/c.png', lines: null },
    ])
    expect(groupTotals(set)).toEqual({ files: 4, added: 5, removed: 0 })
  })

  it('is all nought for no changes', () => {
    expect(groupTotals(changeSet('', []))).toEqual({ files: 0, added: 0, removed: 0 })
  })
})
