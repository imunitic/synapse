import { beforeEach, describe, expect, it } from 'vitest'
import {
  baselineOf,
  ensureBaseline,
  followBaseline,
  followFolder,
  followHead,
  keepBaseline,
  onBaselineChange,
} from './change-baselines.ts'

const TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

beforeEach(() => {
  keepBaseline('s1', null)
  keepBaseline('s2', null)
})

describe('a session baseline', () => {
  it('is taken once, from the folder the host says, and kept', async () => {
    const asked: string[] = []
    const transport = {
      snapshotChanges: (folder: string) => {
        asked.push(folder)
        return Promise.resolve({ tree: TREE, head: 'main' })
      },
    }
    await ensureBaseline(transport, 's1', '/work/widget')
    await ensureBaseline(transport, 's1', '/work/widget')
    expect(baselineOf('s1')).toEqual({ folder: '/work/widget', tree: TREE, head: 'main' })
    expect(asked).toEqual(['/work/widget'])
  })

  it('has no snapshot for a folder that is not in a repository, and is none when git cannot be asked', async () => {
    await ensureBaseline(
      { snapshotChanges: () => Promise.resolve({ tree: null, head: null }) },
      's1',
      '/plain',
    )
    expect(baselineOf('s1')).toEqual({ folder: '/plain', tree: null, head: null })
    await ensureBaseline({ snapshotChanges: () => Promise.reject(new Error('no git')) }, 's2', '/x')
    expect(baselineOf('s2')).toBeNull()
  })

  it('tells those who listen when one is kept or dropped, until they stop', () => {
    let told = 0
    const stop = onBaselineChange(() => (told += 1))
    keepBaseline('s1', { folder: '/a', tree: TREE })
    keepBaseline('s1', null)
    stop()
    keepBaseline('s1', { folder: '/a', tree: TREE })
    expect(told).toBe(2)
    keepBaseline('s1', null)
  })
})

describe('the baseline of a session that a conversation was found in', () => {
  const answering = (tree: string | null, asked: string[] = []) => ({
    snapshotChanges: (folder: string) => {
      asked.push(folder)
      return Promise.resolve({ tree, head: tree === null ? null : 'main' })
    },
  })

  it('is taken for the folder the harness works in, in place of the one the session began in', async () => {
    await ensureBaseline(answering(null), 's1', '/home/me')
    expect(baselineOf('s1')).toEqual({ folder: '/home/me', tree: null, head: null })
    await followBaseline(answering(TREE), 's1', '/home/me/widget', 'claude-1')
    expect(baselineOf('s1')).toEqual({
      folder: '/home/me/widget',
      tree: TREE,
      source: 'claude-1',
      head: 'main',
    })
  })

  it('is taken once for a conversation, and again for the next one', async () => {
    const asked: string[] = []
    await followBaseline(answering(TREE, asked), 's1', '/w/a', 'claude-1')
    await followBaseline(answering(TREE, asked), 's1', '/w/a', 'claude-1')
    expect(asked).toEqual(['/w/a'])
    await followBaseline(answering('b'.repeat(40), asked), 's1', '/w/b', 'codex-2')
    expect(baselineOf('s1')).toMatchObject({ folder: '/w/b', source: 'codex-2' })
  })

  it('leaves the baseline it has when git cannot be asked', async () => {
    keepBaseline('s1', { folder: '/w/a', tree: TREE })
    await followBaseline(
      { snapshotChanges: () => Promise.reject(new Error('no git')) },
      's1',
      '/w/b',
      'claude-1',
    )
    expect(baselineOf('s1')).toEqual({ folder: '/w/a', tree: TREE })
  })
})

describe('a session that switches branches', () => {
  const OTHER = 'b'.repeat(40)
  const THIRD = 'c'.repeat(40)

  // Answers each snapshot with the next tree, at the position it is given.
  function snapshots(trees: string[], head: string, asked: string[] = []) {
    return {
      snapshotChanges: (folder: string) => {
        asked.push(folder)
        return Promise.resolve({ tree: trees.shift() ?? null, head })
      },
    }
  }

  it('takes a new snapshot when it switches to a branch', async () => {
    keepBaseline('s1', { folder: '/w', tree: TREE, head: 'main' })
    const asked: string[] = []
    await followHead(snapshots([OTHER], 'other', asked), 's1', 'other')
    expect(asked).toEqual(['/w'])
    expect(baselineOf('s1')).toEqual({
      folder: '/w',
      tree: OTHER,
      head: 'other',
      switched: true,
    })
  })

  it('takes a new snapshot when it switches back, since the branch has moved on meanwhile', async () => {
    keepBaseline('s1', { folder: '/w', tree: TREE, head: 'main' })
    await followHead(snapshots([OTHER], 'other'), 's1', 'other')
    const asked: string[] = []
    await followHead(snapshots([THIRD], 'main', asked), 's1', 'main')
    expect(asked).toEqual(['/w'])
    expect(baselineOf('s1')).toEqual({ folder: '/w', tree: THIRD, head: 'main', switched: true })
  })

  it('changes nothing on the same branch, for a null position, or outside a repository', async () => {
    keepBaseline('s1', { folder: '/w', tree: TREE, head: 'main' })
    const asked: string[] = []
    await followHead(snapshots([OTHER], 'main', asked), 's1', 'main')
    await followHead(snapshots([OTHER], 'main', asked), 's1', null)
    keepBaseline('s2', { folder: '/plain', tree: null, head: null })
    await followHead(snapshots([OTHER], 'x', asked), 's2', 'x')
    expect(asked).toEqual([])
    expect(baselineOf('s1')).toEqual({ folder: '/w', tree: TREE, head: 'main' })
    expect(baselineOf('s2')).toEqual({ folder: '/plain', tree: null, head: null })
  })

  it('gives a baseline kept before positions were the one it is told of, without a snapshot', async () => {
    keepBaseline('s1', { folder: '/w', tree: TREE })
    const asked: string[] = []
    await followHead(snapshots([OTHER], 'main', asked), 's1', 'main')
    expect(asked).toEqual([])
    expect(baselineOf('s1')).toEqual({ folder: '/w', tree: TREE, head: 'main' })
  })

  it('takes one snapshot at a time, and keeps the baseline when git cannot be asked', async () => {
    keepBaseline('s1', { folder: '/w', tree: TREE, head: 'main' })
    const asked: string[] = []
    const transport = snapshots([OTHER, THIRD], 'other', asked)
    await Promise.all([followHead(transport, 's1', 'other'), followHead(transport, 's1', 'other')])
    expect(asked).toEqual(['/w'])
    keepBaseline('s2', { folder: '/w', tree: TREE, head: 'main' })
    await followHead({ snapshotChanges: () => Promise.reject(new Error('no git')) }, 's2', 'other')
    expect(baselineOf('s2')).toEqual({ folder: '/w', tree: TREE, head: 'main' })
  })

  it('lets go of the snapshot when the session took another baseline meanwhile', async () => {
    keepBaseline('s1', { folder: '/w', tree: TREE, head: 'main' })
    const transport = {
      snapshotChanges: () => {
        keepBaseline('s1', { folder: '/v', tree: THIRD, head: 'main', source: 'codex-2' })
        return Promise.resolve({ tree: OTHER, head: 'other' })
      },
    }
    await followHead(transport, 's1', 'other')
    expect(baselineOf('s1')).toEqual({ folder: '/v', tree: THIRD, head: 'main', source: 'codex-2' })
  })
})

describe('the baseline of a session moved to a folder a person typed', () => {
  const at = (trees: Record<string, string | null>, asked: string[] = []) => ({
    snapshotChanges: (folder: string) => {
      asked.push(folder)
      const tree = trees[folder] === undefined ? TREE : trees[folder]
      return Promise.resolve({ tree, head: 'main' })
    },
  })

  it('moves to the folder, keeps the one it leaves, and restores it on the way back', async () => {
    const asked: string[] = []
    keepBaseline('s1', { folder: '/w/widget', tree: 'aaa', head: 'main', source: 'claude-1' })
    expect(
      await followFolder(at({ '/w/widget-2': 'bbb' }, asked), 's1', ' /w/widget-2 '),
    ).toBeNull()
    expect(baselineOf('s1')).toMatchObject({
      folder: '/w/widget-2',
      tree: 'bbb',
      source: 'claude-1',
    })
    expect(await followFolder(at({}, asked), 's1', '/w/widget')).toBeNull()
    expect(baselineOf('s1')).toMatchObject({ folder: '/w/widget', tree: 'aaa' })
    expect(baselineOf('s1')?.others?.['/w/widget-2']).toMatchObject({ tree: 'bbb' })
    expect(asked).toEqual(['/w/widget-2'])
  })

  it('says why it did not move, and changes nothing', async () => {
    const asked: string[] = []
    expect(await followFolder(at({}, asked), 's1', '/w/a')).toMatch(/not taken yet/)
    keepBaseline('s1', { folder: '/w/a', tree: 'aaa' })
    expect(await followFolder(at({}, asked), 's1', '  ')).toMatch(/Type the path/)
    expect(await followFolder(at({ '/plain': null }, asked), 's1', '/plain')).toMatch(
      /not in a git repository/,
    )
    const refusing = { snapshotChanges: () => Promise.reject(new Error('the folder is not there')) }
    expect(await followFolder(refusing, 's1', '/gone')).toBe('the folder is not there')
    expect(await followFolder(at({}, asked), 's1', '/w/a')).toBeNull()
    expect(baselineOf('s1')).toEqual({ folder: '/w/a', tree: 'aaa' })
  })
})
