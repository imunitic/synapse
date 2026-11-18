import { execFileSync } from 'node:child_process'
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  changesSince,
  commitChanges,
  commitLog,
  headPosition,
  headTree,
  snapshotTree,
} from './changes.ts'

const IDENTITY = {
  GIT_AUTHOR_NAME: 'A',
  GIT_AUTHOR_EMAIL: 'a@example.com',
  GIT_COMMITTER_NAME: 'A',
  GIT_COMMITTER_EMAIL: 'a@example.com',
}

let dir: string

function git(...args: string[]): string {
  return execFileSync('git', args, { cwd: dir, env: { ...process.env, ...IDENTITY } }).toString()
}

// The branch `git init` checked out, which the user's configuration may name.
function branch(): string {
  return git('symbolic-ref', '--short', 'HEAD').trim()
}

async function put(name: string, text: string): Promise<void> {
  await mkdir(join(dir, name, '..'), { recursive: true })
  await writeFile(join(dir, name), text)
}

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-changes-test-'))
  git('init', '-q')
  await put('a.txt', 'one\ntwo\nthree\n')
  await put('gone.txt', 'bye\n')
  await put('.gitignore', 'ignored.log\n')
  git('add', '-A')
  git('commit', '-q', '-m', 'first')
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('snapshotTree', () => {
  it('is the id of a tree, and the same while nothing changes', async () => {
    const first = await snapshotTree(dir)
    expect(first).toMatch(/^[0-9a-f]{40}$/)
    expect(await snapshotTree(dir)).toBe(first)
    await put('a.txt', 'changed\n')
    expect(await snapshotTree(dir)).not.toBe(first)
  })

  it('leaves the repository as it was: no commit, no stash, the real index untouched', async () => {
    await put('a.txt', 'changed\n')
    await put('new.txt', 'new\n')
    const head = git('rev-parse', 'HEAD')
    const status = git('status', '--porcelain=v1')
    const index = await readFile(join(dir, '.git', 'index'))
    await snapshotTree(dir)
    expect(git('rev-parse', 'HEAD')).toBe(head)
    expect(git('status', '--porcelain=v1')).toBe(status)
    expect(git('stash', 'list')).toBe('')
    expect((await readFile(join(dir, '.git', 'index'))).equals(index)).toBe(true)
  })

  it('sees a file written again with the same size in the second of the last commit', async () => {
    // The file is rewritten at once, in the second the index was written, and the snapshot is taken
    // after that second: the copy of the index must not look newer than the index it is a copy of.
    await put('a.txt', 'one\nTWO\nthree\n')
    await new Promise((resolve) => setTimeout(resolve, 1200))
    const tree = (await snapshotTree(dir))!
    expect(git('show', `${tree}:a.txt`)).toBe('one\nTWO\nthree\n')
  })

  it('reads the folder it is given, whatever repository the environment names', async () => {
    const expected = await snapshotTree(dir)
    process.env.GIT_DIR = join(tmpdir(), 'no-such-repository')
    process.env.GIT_INDEX_FILE = join(tmpdir(), 'no-such-index')
    try {
      expect(await snapshotTree(dir)).toBe(expected)
    } finally {
      delete process.env.GIT_DIR
      delete process.env.GIT_INDEX_FILE
    }
  })

  it('is null in a folder that is not in a git repository', async () => {
    const plain = await mkdtemp(join(tmpdir(), 'synapse-plain-'))
    try {
      expect(await snapshotTree(plain)).toBeNull()
    } finally {
      await rm(plain, { recursive: true, force: true })
    }
  })

  it('is refused for a folder that is not there', async () => {
    await expect(snapshotTree(join(dir, 'nope'))).rejects.toMatchObject({ code: 'not_found' })
  })

  it('works in a repository that has no commit yet', async () => {
    const fresh = await mkdtemp(join(tmpdir(), 'synapse-fresh-'))
    try {
      execFileSync('git', ['init', '-q'], { cwd: fresh })
      await writeFile(join(fresh, 'x.txt'), 'x\n')
      expect(await snapshotTree(fresh)).toMatch(/^[0-9a-f]{40}$/)
    } finally {
      await rm(fresh, { recursive: true, force: true })
    }
  })
})

describe('changesSince', () => {
  it('holds the diff of a changed file and nothing else', async () => {
    const before = (await snapshotTree(dir))!
    await put('a.txt', 'one\nTWO\nthree\n')
    const changes = await changesSince(dir, before)
    expect(changes.repository).toBe(true)
    expect(changes.patch).toContain('diff --git a/a.txt b/a.txt')
    expect(changes.patch).toContain('-two')
    expect(changes.patch).toContain('+TWO')
    expect(changes.added).toEqual([])
  })

  it('is empty when nothing changed', async () => {
    const before = (await snapshotTree(dir))!
    expect(await changesSince(dir, before)).toEqual({
      repository: true,
      patch: '',
      added: [],
      head: branch(),
    })
  })

  it('lists a new file by its path and number of lines, and keeps its content out of the patch', async () => {
    const before = (await snapshotTree(dir))!
    await put('src/new.txt', 'a\nb\nc\nd\n')
    const changes = await changesSince(dir, before)
    expect(changes.added).toEqual([{ path: 'src/new.txt', lines: 4 }])
    expect(changes.patch).not.toContain('new.txt')
  })

  it('gives a new file its whole content when it is asked for by its path', async () => {
    const before = (await snapshotTree(dir))!
    await put('new.txt', 'hello\nworld\n')
    const one = await changesSince(dir, before, 'new.txt')
    expect(one.patch).toContain('new file mode')
    expect(one.patch).toContain('+hello')
    expect(one.patch).toContain('+world')
    expect(one.added).toEqual([])
  })

  it('has no number of lines for a new binary file', async () => {
    const before = (await snapshotTree(dir))!
    await writeFile(join(dir, 'blob.bin'), Buffer.from([0, 1, 2, 0, 255, 0]))
    expect((await changesSince(dir, before)).added).toEqual([{ path: 'blob.bin', lines: null }])
  })

  it('holds a deleted file in the patch and a rename as one file', async () => {
    await put('big.txt', Array.from({ length: 30 }, (_, i) => `line ${i}`).join('\n') + '\n')
    git('add', '-A')
    git('commit', '-q', '-m', 'second')
    const before = (await snapshotTree(dir))!
    await rm(join(dir, 'gone.txt'))
    await rm(join(dir, 'big.txt'))
    await put('moved.txt', Array.from({ length: 30 }, (_, i) => `line ${i}`).join('\n') + '\n')
    const changes = await changesSince(dir, before)
    expect(changes.patch).toContain('deleted file mode')
    expect(changes.patch).toContain('rename from big.txt')
    expect(changes.patch).toContain('rename to moved.txt')
    expect(changes.added).toEqual([])
  })

  it('does not show what was already changed when the snapshot was taken', async () => {
    await put('a.txt', 'dirty before the agent\n')
    await put('untracked.txt', 'was here\n')
    const before = (await snapshotTree(dir))!
    await put('a.txt', 'dirty before the agent\nand then the agent\n')
    const changes = await changesSince(dir, before)
    expect(changes.patch).toContain('+and then the agent')
    expect(changes.patch).not.toContain('-three')
    expect(changes.added).toEqual([])
  })

  it('never shows an ignored file', async () => {
    const before = (await snapshotTree(dir))!
    await put('ignored.log', 'noise\n')
    expect(await changesSince(dir, before)).toEqual({
      repository: true,
      patch: '',
      added: [],
      head: branch(),
    })
  })

  it('says there is no repository for a folder that is not in one', async () => {
    const plain = await mkdtemp(join(tmpdir(), 'synapse-plain-'))
    try {
      const before = (await snapshotTree(dir))!
      expect(await changesSince(plain, before)).toEqual({
        repository: false,
        patch: '',
        added: [],
        head: null,
      })
    } finally {
      await rm(plain, { recursive: true, force: true })
    }
  })

  it('refuses a snapshot that is not in the repository, and a path that holds a NUL', async () => {
    await put('a.txt', 'changed\n')
    await expect(changesSince(dir, 'a'.repeat(40))).rejects.toMatchObject({ code: 'not_found' })
    const before = (await snapshotTree(dir))!
    await put('a.txt', 'changed again\n')
    await expect(changesSince(dir, before, 'a\0b')).rejects.toMatchObject({ code: 'bad_request' })
  })

  it('takes a path as a name and not as an option or a pattern', async () => {
    const before = (await snapshotTree(dir))!
    await put('a.txt', 'changed\n')
    expect((await changesSince(dir, before, '--stat')).patch).toBe('')
    expect((await changesSince(dir, before, '*.txt')).patch).toBe('')
    expect((await changesSince(dir, before, 'a.txt')).patch).toContain('+changed')
    await expect(stat(join(dir, 'a.txt'))).resolves.toBeDefined()
  })
})

describe('headTree', () => {
  it('is the tree of the last commit, and changes against it are everything not committed', async () => {
    expect(await headTree(dir)).toBe(git('rev-parse', 'HEAD^{tree}').trim())
    await put('a.txt', 'one\nTWO\nthree\n')
    await put('src/new.txt', 'fresh\n')
    const changes = await changesSince(dir, (await headTree(dir))!)
    expect(changes.patch).toContain('+TWO')
    expect(changes.added).toEqual([{ path: 'src/new.txt', lines: 1 }])
  })

  it('is the empty tree in a repository with no commit, so that every file is new', async () => {
    const fresh = await mkdtemp(join(tmpdir(), 'synapse-fresh-'))
    try {
      execFileSync('git', ['init', '-q'], { cwd: fresh })
      await writeFile(join(fresh, 'x.txt'), 'x\n')
      const empty = await headTree(fresh)
      expect(empty).toMatch(/^[0-9a-f]{40}$/)
      expect(await changesSince(fresh, empty!)).toMatchObject({
        repository: true,
        added: [{ path: 'x.txt', lines: 1 }],
      })
    } finally {
      await rm(fresh, { recursive: true, force: true })
    }
  })

  it('is null outside a repository, and refused for a folder that is not there', async () => {
    const plain = await mkdtemp(join(tmpdir(), 'synapse-plain-'))
    try {
      expect(await headTree(plain)).toBeNull()
    } finally {
      await rm(plain, { recursive: true, force: true })
    }
    await expect(headTree(join(dir, 'nope'))).rejects.toMatchObject({ code: 'not_found' })
  })
})

describe('headPosition', () => {
  it('is the branch checked out, and follows a switch', async () => {
    expect(await headPosition(dir)).toBe(branch())
    git('checkout', '-q', '-b', 'other')
    expect(await headPosition(dir)).toBe('other')
    const changes = await changesSince(dir, (await snapshotTree(dir))!)
    expect(changes.head).toBe('other')
  })

  it('is the commit when HEAD is detached', async () => {
    const commit = git('rev-parse', 'HEAD').trim()
    git('checkout', '-q', '--detach')
    expect(await headPosition(dir)).toBe(commit)
  })

  it('is the branch before its first commit, and null outside a repository', async () => {
    const fresh = await mkdtemp(join(tmpdir(), 'synapse-fresh-'))
    const plain = await mkdtemp(join(tmpdir(), 'synapse-plain-'))
    try {
      execFileSync('git', ['init', '-q', '-b', 'start'], { cwd: fresh })
      expect(await headPosition(fresh)).toBe('start')
      expect(await headPosition(plain)).toBeNull()
    } finally {
      await rm(fresh, { recursive: true, force: true })
      await rm(plain, { recursive: true, force: true })
    }
  })
})

// Commits a change with the message it is given and says its hash.
async function commitOf(message: string, files: Record<string, string>): Promise<string> {
  for (const [name, text] of Object.entries(files)) await put(name, text)
  git('add', '-A')
  git('commit', '-q', '-m', message)
  return git('rev-parse', 'HEAD').trim()
}

describe('commitLog', () => {
  it('lists the commits of HEAD newest first, with who made them and when', async () => {
    await commitOf('second', { 'b.txt': 'b\n' })
    await commitOf('third', { 'c.txt': 'c\n' })
    const log = await commitLog(dir, 10)
    expect(log.repository).toBe(true)
    expect(log.more).toBe(false)
    expect(log.commits.map((c) => c.subject)).toEqual(['third', 'second', 'first'])
    expect(log.commits[0]?.hash).toBe(git('rev-parse', 'HEAD').trim())
    expect(log.commits[0]?.author).toBe('A')
    expect(Number.isNaN(Date.parse(log.commits[0]?.time ?? ''))).toBe(false)
  })

  it('counts the lines each commit added and removed, a merge against its first parent', async () => {
    await commitOf('add a line', { 'b.txt': 'b\n' })
    await commitOf('change a line', { 'a.txt': 'one\nTWO\nthree\n' })
    const main = branch()
    git('checkout', '-q', '-b', 'side')
    await commitOf('on side', { 's.txt': 's1\ns2\n' })
    git('checkout', '-q', main)
    git('merge', '-q', '--no-ff', '-m', 'merge side', 'side')
    const log = await commitLog(dir, 10)
    const counts = log.commits.map((c) => [c.subject, c.added, c.removed])
    expect(counts).toEqual([
      ['merge side', 2, 0],
      ['change a line', 1, 1],
      ['add a line', 1, 0],
      ['first', 5, 0],
    ])
  })

  it('gives a page at a time, from the one after the last already listed', async () => {
    await commitOf('second', { 'b.txt': 'b\n' })
    await commitOf('third', { 'c.txt': 'c\n' })
    const first = await commitLog(dir, 2)
    expect(first.commits.map((c) => c.subject)).toEqual(['third', 'second'])
    expect(first.more).toBe(true)
    const next = await commitLog(dir, 2, first.commits[1]?.hash)
    expect(next.commits.map((c) => c.subject)).toEqual(['first'])
    expect(next.more).toBe(false)
  })

  it('follows the first parent, so a merge is one commit and what it brought in is not listed', async () => {
    const main = branch()
    git('checkout', '-q', '-b', 'side')
    await commitOf('on side', { 's.txt': 's\n' })
    git('checkout', '-q', main)
    git('merge', '-q', '--no-ff', '-m', 'merge side', 'side')
    const log = await commitLog(dir, 10)
    expect(log.commits.map((c) => c.subject)).toEqual(['merge side', 'first'])
  })

  it('keeps a subject with a tab, and gives a subject of two lines as one', async () => {
    await commitOf('a\tb', { 'b.txt': 'b\n' })
    await commitOf('line one\nline two', { 'c.txt': 'c\n' })
    const log = await commitLog(dir, 10)
    expect(log.commits.map((c) => c.subject)).toEqual(['line one line two', 'a\tb', 'first'])
  })

  it('has no commits before the first, and no repository outside one', async () => {
    const fresh = await mkdtemp(join(tmpdir(), 'synapse-fresh-'))
    const plain = await mkdtemp(join(tmpdir(), 'synapse-plain-'))
    try {
      execFileSync('git', ['init', '-q'], { cwd: fresh })
      expect(await commitLog(fresh, 10)).toEqual({ repository: true, commits: [], more: false })
      expect(await commitLog(plain, 10)).toEqual({ repository: false, commits: [], more: false })
    } finally {
      await rm(fresh, { recursive: true, force: true })
      await rm(plain, { recursive: true, force: true })
    }
  })

  it('refuses a cursor that is not a hash, and one that is not in the repository', async () => {
    await expect(commitLog(dir, 10, '--all')).rejects.toMatchObject({ code: 'bad_request' })
    await expect(commitLog(dir, 10, 'HEAD')).rejects.toMatchObject({ code: 'bad_request' })
    await expect(commitLog(dir, 10, 'abcdef0')).rejects.toMatchObject({ code: 'not_found' })
  })
})

describe('commitChanges', () => {
  it('is what a commit changed against its parent: a changed file in the patch, a new one listed', async () => {
    const hash = await commitOf('change', { 'a.txt': 'one\nTWO\nthree\n', 'src/new.txt': 'x\ny\n' })
    const changes = await commitChanges(dir, hash)
    expect(changes.repository).toBe(true)
    expect(changes.patch).toContain('-two')
    expect(changes.patch).toContain('+TWO')
    expect(changes.patch).not.toContain('src/new.txt')
    expect(changes.added).toEqual([{ path: 'src/new.txt', lines: 2 }])
    expect(changes.head).toBe(branch())
  })

  it('compares the first commit with nothing, so every file of it is new', async () => {
    const first = git('rev-list', '--max-parents=0', 'HEAD').trim()
    const changes = await commitChanges(dir, first)
    expect(changes.added.map((f) => f.path).sort()).toEqual(['.gitignore', 'a.txt', 'gone.txt'])
  })

  it('gives one file whole when asked for by its path, and a rename as one file', async () => {
    const added = await commitOf('add', { 'src/new.txt': 'x\ny\n' })
    expect((await commitChanges(dir, added, 'src/new.txt')).patch).toContain('+y')
    git('mv', 'gone.txt', 'kept.txt')
    git('commit', '-q', '-m', 'rename')
    const renamed = await commitChanges(dir, git('rev-parse', 'HEAD').trim())
    expect(renamed.patch).toContain('rename from gone.txt')
    expect(renamed.patch).toContain('rename to kept.txt')
  })

  it('shows a merge against the branch it was merged into', async () => {
    const main = branch()
    git('checkout', '-q', '-b', 'side')
    await commitOf('on side', { 's.txt': 's\n' })
    git('checkout', '-q', main)
    git('merge', '-q', '--no-ff', '-m', 'merge side', 'side')
    const changes = await commitChanges(dir, git('rev-parse', 'HEAD').trim())
    expect(changes.added).toEqual([{ path: 's.txt', lines: 1 }])
  })

  it('refuses what is not a commit hash, a commit that is not there, and a path with a NUL', async () => {
    await expect(commitChanges(dir, 'HEAD')).rejects.toMatchObject({ code: 'bad_request' })
    await expect(commitChanges(dir, '--stat')).rejects.toMatchObject({ code: 'bad_request' })
    await expect(commitChanges(dir, 'abcdef0')).rejects.toMatchObject({ code: 'not_found' })
    const hash = git('rev-parse', 'HEAD').trim()
    await expect(commitChanges(dir, hash, 'a\0b')).rejects.toMatchObject({ code: 'bad_request' })
  })

  it('says there is no repository for a folder outside one', async () => {
    const plain = await mkdtemp(join(tmpdir(), 'synapse-plain-'))
    try {
      expect(await commitChanges(plain, 'abcdef0')).toEqual({
        repository: false,
        patch: '',
        added: [],
        head: null,
      })
    } finally {
      await rm(plain, { recursive: true, force: true })
    }
  })
})
