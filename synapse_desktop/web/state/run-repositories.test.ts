import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Snapshot } from '../../shared/changes.ts'
import { messages } from '../../shared/messages.ts'
import { fakeTransport } from '../domain/fake-transport.ts'
import { memoryStorage } from './memory-storage.ts'
import {
  addRunRepository,
  endRunRepositories,
  forgetGoneRuns,
  moveRunFolder,
  onRunRepositoriesChange,
  removeRunRepository,
  rereadRunRepositories,
  runFolderOf,
  runFoldersShown,
  runRepositoriesOf,
} from './run-repositories.ts'

const HEAD = '1111111111111111111111111111111111111111'
const WORK = '2222222222222222222222222222222222222222'
const KEY = 'synapse-desktop.run-folders'
const EARLIER_KEY = 'synapse-desktop.run-repositories'
const RUN_DIR = '/work/run'
const RECORDS = '/work/.synapse/executions'

const NOT_ROOT = 'the folder is not the root of a git repository'
const anyKey: unknown = expect.stringMatching(/^[A-Za-z0-9_-]{1,64}$/)

// Whether a folder is a repository root or inside one of them.
function inRepository(roots: string[], folder: string): boolean {
  const trimmed = folder.replace(/\/+$/, '')
  return roots.some((root) => trimmed === root || trimmed.startsWith(`${root}/`))
}

// The fake transport, with git answered as the hosts answer it: the roots of the repositories, a
// snapshot of any folder in one, a pin only at a root, and what was pinned.
function world(repositories: string[] = ['/work/api', '/work/web', RUN_DIR]) {
  const pinned: string[] = []
  const unpinned: string[] = []
  const snapshots: string[] = []
  let pinFails = false
  const transport = {
    ...fakeTransport({
      files: {},
      paths: { definitionDirs: [], recordsDir: RECORDS },
    }),
    snapshotChanges(folder: string, of?: 'head'): Promise<Snapshot> {
      snapshots.push(`${folder}${of === undefined ? '' : ` ${of}`}`)
      return Promise.resolve(
        inRepository(repositories, folder)
          ? { tree: of === 'head' ? HEAD : WORK, head: 'main' }
          : { tree: null, head: null },
      )
    },
    pinSnapshot(folder: string, ref: string, tree: string) {
      if (pinFails) return Promise.reject(new Error('cannot pin'))
      if (!repositories.includes(folder)) return Promise.reject(new Error(NOT_ROOT))
      pinned.push(`${folder} ${ref}=${tree}`)
      return Promise.resolve()
    },
    unpinSnapshot(folder: string, ref: string) {
      unpinned.push(`${folder} ${ref}`)
      return Promise.resolve()
    },
  }
  return {
    transport,
    pinned,
    unpinned,
    snapshots,
    failPins: (fails: boolean) => (pinFails = fails),
  }
}

interface Entry {
  folder: string
  key: string
  start: string
  end: string | null
}

interface Stored {
  shown: string | null
  added: Entry[]
  movedTo: Entry[]
}

// What localStorage holds for a run.
function stored(executionId: string): Stored | undefined {
  const all = JSON.parse(localStorage.getItem(KEY) ?? '{}') as Record<string, Stored>
  return all[executionId]
}

// The entry of a folder kept for a run, added or moved to.
function entryOf(executionId: string, folder: string): Entry {
  const run = stored(executionId)
  const entry = [...(run?.added ?? []), ...(run?.movedTo ?? [])].find(
    (one) => one.folder === folder,
  )
  if (entry === undefined) throw new Error(`${folder} is not kept for ${executionId}`)
  return entry
}

// The app's ref for a folder kept for a run, as the hosts take it.
function ref(executionId: string, folder: string, end: 'start' | 'end'): string {
  return `desktop/${executionId}/${entryOf(executionId, folder).key}/${end}`
}

// What `changes.unpin` was asked for the two refs of each folder, in the order given.
function refsOf(executionId: string, ...folders: string[]): string[] {
  return folders.flatMap((folder) =>
    (['start', 'end'] as const).map((end) => `${folder} ${ref(executionId, folder, end)}`),
  )
}

beforeEach(() => {
  vi.stubGlobal('localStorage', memoryStorage())
  rereadRunRepositories()
})

afterEach(() => {
  vi.unstubAllGlobals()
  rereadRunRepositories()
})

describe('a repository added to a run', () => {
  it('pins the tree of its HEAD as the start of the run, and is kept', async () => {
    const { transport, pinned, snapshots } = world()
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, ' /work/api ')).toBeNull()
    expect(snapshots).toEqual(['/work/api head'])
    expect(pinned).toEqual([`/work/api ${ref('exec-1', '/work/api', 'start')}=${HEAD}`])
    expect(runRepositoriesOf('exec-1')).toEqual([
      { folder: '/work/api', key: anyKey, records: RECORDS, start: HEAD, end: null },
    ])
    expect(runRepositoriesOf('exec-2')).toEqual([])
  })

  it('pins names of its own for each folder and each run, none among the run’s own', async () => {
    const { transport, pinned } = world()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/web')
    await addRunRepository(transport, 'exec-2', RUN_DIR, '/work/api')
    await endRunRepositories(transport, 'exec-1')
    const names = pinned.map((one) => one.split(/[ =]/)[1])
    expect(new Set(names).size).toBe(5)
    for (const name of names) {
      expect(name).not.toMatch(/^runs\//)
      expect(
        messages['changes.unpin'].params.safeParse({ folder: '/w', ref: name }).success,
        name,
      ).toBe(true)
    }
  })

  it('is one entry with or without a trailing separator', async () => {
    const { transport, pinned } = world()
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, ' /work/api// ')).toBeNull()
    for (const folder of ['/work/api', '/work/api/'])
      expect(await addRunRepository(transport, 'exec-1', RUN_DIR, folder)).toBe(
        'That repository is added already.',
      )
    expect(runRepositoriesOf('exec-1').map((one) => one.folder)).toEqual(['/work/api'])
    expect(pinned).toHaveLength(1)
  })

  it('pins once, and keeps one entry, when it is added twice at once', async () => {
    const { transport, pinned, failPins } = world()
    const answers = await Promise.all([
      addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api'),
      addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api/'),
    ])
    expect(answers).toEqual([null, 'That repository is being added.'])
    expect(pinned).toHaveLength(1)
    expect(runRepositoriesOf('exec-1')).toHaveLength(1)
    // An add that failed does not hold the folder.
    failPins(true)
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/web')).toBe('cannot pin')
    failPins(false)
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/web')).toBeNull()
  })

  it('does not read an entry under the earlier storage key', async () => {
    const entry = { folder: '/work/api', records: RECORDS, start: HEAD, end: null }
    localStorage.setItem(EARLIER_KEY, JSON.stringify({ 'exec-1': [entry] }))
    rereadRunRepositories()
    const { transport, pinned, unpinned } = world()
    expect(runRepositoriesOf('exec-1')).toEqual([])
    await endRunRepositories(transport, 'exec-1')
    await forgetGoneRuns(transport, RECORDS, [])
    expect(pinned).toEqual([])
    expect(unpinned).toEqual([])
  })

  it('is kept in the order added', async () => {
    const { transport } = world()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/web')
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    expect(runRepositoriesOf('exec-1').map((one) => one.folder)).toEqual(['/work/web', '/work/api'])
  })

  it('is refused when the folder is not in a repository, or is added already', async () => {
    const { transport, pinned } = world()
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, '/plain')).toBe(
      'That folder is not in a git repository.',
    )
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, '  ')).toBe(
      'Type the path of a folder.',
    )
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')).toBe(
      'That repository is added already.',
    )
    expect(pinned).toHaveLength(1)
    expect(runRepositoriesOf('exec-1')).toHaveLength(1)
  })

  it('is refused, and pins nothing, when it is the run’s own repository folder or around it', async () => {
    const { transport, pinned, snapshots } = world()
    for (const folder of [RUN_DIR, `${RUN_DIR}/`, '/work'])
      expect(await addRunRepository(transport, 'exec-1', RUN_DIR, folder)).toBe(
        'That folder is in the run’s own repository, which is shown already.',
      )
    // Only the run's own folder is looked at, to learn that it is in a repository.
    expect(new Set(snapshots)).toEqual(new Set([`${RUN_DIR} head`]))
    expect(pinned).toEqual([])
    expect(runRepositoriesOf('exec-1')).toEqual([])
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/runner')).toBe(
      'That folder is not in a git repository.',
    )
  })

  it('is refused when it is the root of the file system or of a drive, around the run’s folder', async () => {
    for (const [runDirectory, roots] of [
      [RUN_DIR, ['/']],
      ['C:\\work\\run', ['C:\\', 'C:/']],
      ['C:/work/run', ['C:\\', 'C:/']],
    ] as const) {
      const { transport, pinned } = world([runDirectory])
      for (const root of roots)
        expect(
          await addRunRepository(transport, 'exec-1', runDirectory, root),
          `${root} around ${runDirectory}`,
        ).toBe('That folder is in the run’s own repository, which is shown already.')
      expect(pinned).toEqual([])
    }
    // The root of another drive is not around it.
    const { transport } = world(['C:\\work\\run'])
    expect(await addRunRepository(transport, 'exec-1', 'C:\\work\\run', 'D:\\')).toBe(
      'That folder is not in a git repository.',
    )
  })

  it('keeps the separator of a drive root', async () => {
    const { transport, pinned } = world(['C:\\'])
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, ' C:\\ ')).toBeNull()
    expect(runRepositoriesOf('exec-1').map((one) => one.folder)).toEqual(['C:\\'])
    expect(pinned).toEqual([`C:\\ ${ref('exec-1', 'C:\\', 'start')}=${HEAD}`])
  })

  it('is refused by the host, and pins nothing, when it is a plain folder inside the run’s repository', async () => {
    const { transport, pinned } = world()
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, `${RUN_DIR}/src`)).toBe(NOT_ROOT)
    expect(pinned).toEqual([])
    expect(runRepositoriesOf('exec-1')).toEqual([])
  })

  it('is added when it is a nested repository inside the run’s repository', async () => {
    const nested = `${RUN_DIR}/vendor/lib`
    const { transport, pinned } = world([RUN_DIR, nested])
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, nested)).toBeNull()
    expect(pinned).toEqual([`${nested} ${ref('exec-1', nested, 'start')}=${HEAD}`])
    expect(runRepositoriesOf('exec-1').map((one) => one.folder)).toEqual([nested])
  })

  it('is added from inside the run’s folder when that folder is a repository itself (a home folder in git)', async () => {
    const home = '/Users/me'
    const { transport, pinned } = world([home, `${home}/work/api`])
    expect(await addRunRepository(transport, 'exec-1', home, `${home}/work/api`)).toBeNull()
    expect(pinned).toEqual([
      `${home}/work/api ${ref('exec-1', `${home}/work/api`, 'start')}=${HEAD}`,
    ])
  })

  it('is added from inside the run’s folder when that folder is not in a repository', async () => {
    const home = '/Users/me'
    const { transport, pinned } = world([`${home}/work/api`])
    expect(await addRunRepository(transport, 'exec-1', home, `${home}/work/api`)).toBeNull()
    expect(pinned).toEqual([
      `${home}/work/api ${ref('exec-1', `${home}/work/api`, 'start')}=${HEAD}`,
    ])
    expect(runRepositoriesOf('exec-1').map((one) => one.folder)).toEqual([`${home}/work/api`])
  })

  it('is not kept when its start cannot be pinned', async () => {
    const { transport, failPins } = world()
    failPins(true)
    expect(await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')).toBe('cannot pin')
    expect(runRepositoriesOf('exec-1')).toEqual([])
  })

  it('tells those who listen when it is kept, until they stop', async () => {
    const { transport } = world()
    let told = 0
    const stop = onRunRepositoriesChange(() => (told += 1))
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    stop()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/web')
    expect(told).toBe(1)
  })

  it('survives a fresh read of localStorage', async () => {
    const { transport } = world()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    rereadRunRepositories()
    const entry = { folder: '/work/api', key: anyKey, records: RECORDS, start: HEAD, end: null }
    expect(runRepositoriesOf('exec-1')).toEqual([entry])
    expect(stored('exec-1')).toEqual({ shown: null, added: [entry], movedTo: [] })
  })
})

describe('a repository taken off a run', () => {
  it('has both of its refs unpinned and is forgotten; the others stay', async () => {
    const { transport, unpinned } = world()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/web')
    await addRunRepository(transport, 'exec-2', RUN_DIR, '/work/api')
    const own = refsOf('exec-1', '/work/api')
    await removeRunRepository(transport, 'exec-1', '/work/api')
    expect(unpinned).toEqual(own)
    expect(runRepositoriesOf('exec-2')).toHaveLength(1)
    expect(runRepositoriesOf('exec-1').map((one) => one.folder)).toEqual(['/work/web'])
    rereadRunRepositories()
    expect(runRepositoriesOf('exec-1').map((one) => one.folder)).toEqual(['/work/web'])
  })

  it('unpins nothing for a folder that is not added', async () => {
    const { transport, unpinned } = world()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    await removeRunRepository(transport, 'exec-1', '/work/web')
    expect(unpinned).toEqual([])
    expect(runRepositoriesOf('exec-1')).toHaveLength(1)
  })

  it('is forgotten even when a ref cannot be deleted', async () => {
    const { transport } = world()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    const failing = { unpinSnapshot: () => Promise.reject(new Error('cannot unpin')) }
    await removeRunRepository(failing, 'exec-1', '/work/api')
    expect(runRepositoriesOf('exec-1')).toEqual([])
  })
})

describe('the end of a run in its added repositories', () => {
  it('pins the working tree as the end, once', async () => {
    const { transport, pinned } = world()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/web')
    pinned.length = 0
    await endRunRepositories(transport, 'exec-1')
    expect(pinned).toEqual([
      `/work/api ${ref('exec-1', '/work/api', 'end')}=${WORK}`,
      `/work/web ${ref('exec-1', '/work/web', 'end')}=${WORK}`,
    ])
    expect(runRepositoriesOf('exec-1').map((one) => one.end)).toEqual([WORK, WORK])
    await endRunRepositories(transport, 'exec-1')
    expect(pinned).toHaveLength(2)
  })

  it('keeps no end when the pin fails, and pins it at the next call', async () => {
    const { transport, pinned, failPins } = world()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    pinned.length = 0
    failPins(true)
    await endRunRepositories(transport, 'exec-1')
    expect(runRepositoriesOf('exec-1')[0]?.end).toBeNull()
    failPins(false)
    await endRunRepositories(transport, 'exec-1')
    expect(pinned).toEqual([`/work/api ${ref('exec-1', '/work/api', 'end')}=${WORK}`])
    expect(runRepositoriesOf('exec-1')[0]?.end).toBe(WORK)
  })
})

describe('a run whose record is gone', () => {
  it('has both refs unpinned in each of its repositories and is forgotten; a known one is kept', async () => {
    const { transport, unpinned } = world()
    await addRunRepository(transport, 'gone', RUN_DIR, '/work/api')
    await addRunRepository(transport, 'gone', RUN_DIR, '/work/web')
    await addRunRepository(transport, 'known', RUN_DIR, '/work/api')
    const own = refsOf('gone', '/work/api', '/work/web')
    await forgetGoneRuns(transport, RECORDS, ['known', 'other'])
    expect(unpinned).toEqual(own)
    expect(runRepositoriesOf('gone')).toEqual([])
    expect(runRepositoriesOf('known')).toHaveLength(1)
    rereadRunRepositories()
    expect(Object.keys(JSON.parse(localStorage.getItem(KEY) ?? '{}'))).toEqual(['known'])
  })

  it('is not taken for gone when another records directory is listed', async () => {
    const { transport, unpinned } = world()
    await addRunRepository(transport, 'elsewhere', RUN_DIR, '/work/api')
    await forgetGoneRuns(transport, '/other/.synapse/executions', [])
    expect(unpinned).toEqual([])
    expect(runRepositoriesOf('elsewhere')).toHaveLength(1)
  })

  it('is never taken for gone when it was added with no records directory', async () => {
    const { transport, unpinned } = world()
    const noRecords = {
      ...transport,
      getPaths: () => Promise.resolve({ definitionDirs: [], recordsDir: null }),
    }
    await addRunRepository(noRecords, 'exec-1', RUN_DIR, '/work/api')
    await forgetGoneRuns(transport, RECORDS, [])
    expect(unpinned).toEqual([])
    expect(runRepositoriesOf('exec-1')).toHaveLength(1)
  })

  it('is not taken for gone from an empty listing when there is no work directory', async () => {
    const { transport, unpinned } = world()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    await forgetGoneRuns(transport, null, [])
    expect(unpinned).toEqual([])
    expect(runRepositoriesOf('exec-1')).toHaveLength(1)
  })
})

// A world with two worktrees besides the run's folder, and the move of exec-1's view in it.
function movingWorld(repositories = ['/work/api', '/work/web', RUN_DIR]) {
  const made = world(repositories)
  const move = (typed: string, runDirectory = RUN_DIR) =>
    moveRunFolder(made.transport, 'exec-1', runDirectory, typed)
  const add = (typed: string) => addRunRepository(made.transport, 'exec-1', RUN_DIR, typed)
  return { ...made, move, add }
}

function addedFolders(): string[] {
  return runRepositoriesOf('exec-1').map((one) => one.folder)
}

describe('a run’s view moved to a folder', () => {
  it('pins the tree of its HEAD as the start, and shows it without listing it as added', async () => {
    const { move, pinned, snapshots } = movingWorld()
    expect(runFolderOf('exec-1')).toBeNull()
    expect(await move(' /work/api// ')).toBeNull()
    expect(runFolderOf('exec-1')).toBe('/work/api')
    expect(runFolderOf('exec-2')).toBeNull()
    expect(snapshots).toEqual(['/work/api head'])
    expect(pinned).toEqual([`/work/api ${ref('exec-1', '/work/api', 'start')}=${HEAD}`])
    expect(runRepositoriesOf('exec-1')).toEqual([])
  })

  it('keeps the choice and the starts through a fresh read of localStorage', async () => {
    const { move } = movingWorld()
    await move('/work/api')
    await move('/work/web')
    rereadRunRepositories()
    expect(runFolderOf('exec-1')).toBe('/work/web')
    const entry = (folder: string) => ({
      folder,
      key: anyKey,
      records: RECORDS,
      start: HEAD,
      end: null,
    })
    expect(stored('exec-1')).toEqual({
      shown: '/work/web',
      added: [],
      movedTo: [entry('/work/api'), entry('/work/web')],
    })
  })

  it('is refused for an empty path', async () => {
    const { move, pinned, snapshots } = movingWorld()
    await move('/work/api')
    pinned.length = 0
    snapshots.length = 0
    expect(await move('  ')).toBe('Type the path of a folder.')
    expect(runFolderOf('exec-1')).toBe('/work/api')
    expect([pinned, snapshots]).toEqual([[], []])
  })

  it('goes back to the run’s own folder, taking and pinning nothing', async () => {
    const { move, pinned, unpinned, snapshots } = movingWorld()
    await move('/work/api')
    const key = entryOf('exec-1', '/work/api').key
    pinned.length = 0
    snapshots.length = 0
    expect(await move(` ${RUN_DIR}// `)).toBeNull()
    expect(runFolderOf('exec-1')).toBeNull()
    rereadRunRepositories()
    expect(runFolderOf('exec-1')).toBeNull()
    // The folder left keeps its entry and refs.
    expect(entryOf('exec-1', '/work/api')).toMatchObject({ key, start: HEAD })
    expect([pinned, unpinned, snapshots]).toEqual([[], [], []])
  })

  it('goes back to the run’s own folder when that folder is in no repository', async () => {
    const { move, pinned, snapshots } = movingWorld(['/work/api'])
    await move('/work/api', '/plain/')
    pinned.length = 0
    snapshots.length = 0
    expect(await move('/plain', '/plain/')).toBeNull()
    expect(runFolderOf('exec-1')).toBeNull()
    expect([pinned, snapshots]).toEqual([[], []])
  })

  it('keeps nothing of a run when it is in its own folder already', async () => {
    const { move, pinned, snapshots } = movingWorld()
    expect(await move(RUN_DIR)).toBeNull()
    expect(localStorage.getItem(KEY)).toBeNull()
    expect([pinned, snapshots]).toEqual([[], []])
  })

  it('shows a folder moved to earlier with the start it has, taking HEAD once', async () => {
    const { move, pinned, unpinned, snapshots } = movingWorld()
    await move('/work/api')
    const first = entryOf('exec-1', '/work/api')
    await move('/work/web')
    expect(await move('/work/api/')).toBeNull()
    expect(runFolderOf('exec-1')).toBe('/work/api')
    expect(entryOf('exec-1', '/work/api')).toEqual(first)
    expect(snapshots).toEqual(['/work/api head', '/work/web head'])
    expect(pinned).toHaveLength(2)
    expect(unpinned).toEqual([])
  })

  it('stays where it was when the folder is in no repository', async () => {
    const { move, pinned } = movingWorld()
    expect(await move('/plain')).toBe('That folder is not in a git repository.')
    expect(runFolderOf('exec-1')).toBeNull()
    expect(localStorage.getItem(KEY)).toBeNull()
    await move('/work/api')
    expect(await move('/plain')).toBe('That folder is not in a git repository.')
    expect(runFolderOf('exec-1')).toBe('/work/api')
    expect(pinned).toHaveLength(1)
  })

  it('stays where it was, with the host’s reason, when the folder is not a repository root', async () => {
    const { move, pinned } = movingWorld()
    await move('/work/api')
    expect(await move('/work/web/src')).toBe(NOT_ROOT)
    expect(runFolderOf('exec-1')).toBe('/work/api')
    expect(stored('exec-1')?.movedTo.map((one) => one.folder)).toEqual(['/work/api'])
    expect(pinned).toHaveLength(1)
  })

  it('keeps nothing when the pin fails, and can be moved there afterwards', async () => {
    const { move, failPins } = movingWorld()
    failPins(true)
    expect(await move('/work/api')).toBe('cannot pin')
    expect(runFolderOf('exec-1')).toBeNull()
    expect(localStorage.getItem(KEY)).toBeNull()
    failPins(false)
    expect(await move('/work/api')).toBeNull()
    expect(runFolderOf('exec-1')).toBe('/work/api')
  })

  it('refuses a second move while one is going on, in that run only', async () => {
    const { transport, move, pinned } = movingWorld()
    await move('/work/api')
    await move(RUN_DIR)
    pinned.length = 0
    const first = move('/work/web')
    // Refused also for a folder that would take nothing.
    for (const folder of ['/work/web', '/work/api', RUN_DIR])
      expect(await move(folder)).toBe('The view is moving to another folder.')
    expect(await moveRunFolder(transport, 'exec-2', RUN_DIR, '/work/api')).toBeNull()
    expect(await first).toBeNull()
    expect(runFolderOf('exec-1')).toBe('/work/web')
    expect(pinned.filter((one) => one.includes('desktop/exec-1/'))).toHaveLength(1)
    expect(await move('/work/api')).toBeNull()
  })

  it('and an add of the same folder do not both take a start', async () => {
    const { move, add, pinned } = movingWorld()
    const moved = move('/work/api')
    expect(await add('/work/api')).toBe('The view is moving to that folder.')
    expect(await moved).toBeNull()
    const added = add('/work/web')
    expect(await move('/work/web')).toBe('That repository is being added.')
    expect(await added).toBeNull()
    expect(pinned).toHaveLength(2)
    expect(runFolderOf('exec-1')).toBe('/work/api')
    expect(addedFolders()).toEqual(['/work/web'])
  })

  it('to an added repository takes it off the added list, keeping its start and refs', async () => {
    const { move, add, pinned, unpinned, snapshots } = movingWorld()
    await add('/work/api')
    await add('/work/web')
    const entry = entryOf('exec-1', '/work/api')
    pinned.length = 0
    snapshots.length = 0
    expect(await move('/work/api')).toBeNull()
    expect(runFolderOf('exec-1')).toBe('/work/api')
    expect(addedFolders()).toEqual(['/work/web'])
    expect(entryOf('exec-1', '/work/api')).toEqual(entry)
    expect([pinned, unpinned, snapshots]).toEqual([[], [], []])
    // Moving away does not list it as added again.
    await move(RUN_DIR)
    expect(addedFolders()).toEqual(['/work/web'])
  })

  it('is told to those who listen when the choice changes', async () => {
    const { move } = movingWorld()
    const seen: (string | null)[] = []
    const stop = onRunRepositoriesChange(() => seen.push(runFolderOf('exec-1')))
    await move('/work/api')
    await move('/work/api')
    await move('/work/web')
    await move('/work/api')
    await move(RUN_DIR)
    await move(RUN_DIR)
    await move('/plain')
    stop()
    expect(seen).toEqual(['/work/api', '/work/web', '/work/api', null])
  })
})

describe('adding a repository to a run whose view can move', () => {
  it('shows a folder moved to earlier as added, with the start it has', async () => {
    const { move, add, pinned, snapshots } = movingWorld()
    await add('/work/web')
    await move('/work/api')
    const entry = entryOf('exec-1', '/work/api')
    await move(RUN_DIR)
    pinned.length = 0
    snapshots.length = 0
    expect(await add('/work/api/')).toBeNull()
    expect(addedFolders()).toEqual(['/work/web', '/work/api'])
    expect(entryOf('exec-1', '/work/api')).toEqual(entry)
    expect(stored('exec-1')?.movedTo).toEqual([])
    expect([pinned, snapshots]).toEqual([[], []])
    expect(await add('/work/api')).toBe('That repository is added already.')
  })

  it('is refused for the folder shown now', async () => {
    const { move, add, pinned } = movingWorld()
    await move('/work/api')
    expect(await add('/work/api/')).toBe('That repository is shown already.')
    expect(addedFolders()).toEqual([])
    expect(runFolderOf('exec-1')).toBe('/work/api')
    expect(pinned).toHaveLength(1)
  })

  it('is refused for a folder around the run’s own that the view was moved to earlier', async () => {
    // The run works in a plain folder of the repository /work.
    const { move, add, pinned } = movingWorld(['/work', '/work/web'])
    await move('/work')
    await move('/work/web')
    const entry = entryOf('exec-1', '/work')
    expect(await add('/work/')).toBe(
      'That folder is in the run’s own repository. To see it, type the run’s own folder in the folder bar.',
    )
    await move(RUN_DIR)
    expect(await add('/work')).toBe(
      'That folder is in the run’s own repository, which is shown already.',
    )
    expect(addedFolders()).toEqual([])
    expect(stored('exec-1')?.movedTo.map((one) => one.folder)).toEqual(['/work', '/work/web'])
    expect(entryOf('exec-1', '/work')).toEqual(entry)
    expect(pinned).toHaveLength(2)
  })

  it('is refused when the view moves to the folder while the run’s own is looked at', async () => {
    const repositories = ['/work']
    const { move, add } = movingWorld(repositories)
    await move('/work')
    await move(RUN_DIR)
    // The run's folder is in no repository by now, so nothing around it is refused for that.
    repositories.length = 0
    const added = add('/work')
    expect(await move('/work')).toBeNull()
    expect(await added).toBe('That repository is shown already.')
    expect(runFolderOf('exec-1')).toBe('/work')
    expect(addedFolders()).toEqual([])
  })

  it('is refused for the run’s own folder, without saying it is shown while the view is elsewhere', async () => {
    const { move, add, pinned } = movingWorld()
    await move('/work/api')
    for (const folder of [RUN_DIR, '/work'])
      expect(await add(folder)).toBe(
        'That folder is in the run’s own repository. To see it, type the run’s own folder in the folder bar.',
      )
    await move(RUN_DIR)
    expect(await add(RUN_DIR)).toBe(
      'That folder is in the run’s own repository, which is shown already.',
    )
    expect(addedFolders()).toEqual([])
    expect(pinned).toHaveLength(1)
  })

  it('and taking it off deletes its refs and forgets that it was moved to', async () => {
    const { transport, move, add, unpinned, snapshots } = movingWorld()
    await move('/work/api')
    await move('/work/web')
    await add('/work/api')
    const own = refsOf('exec-1', '/work/api')
    const before = entryOf('exec-1', '/work/api').key
    await removeRunRepository(transport, 'exec-1', '/work/api')
    expect(unpinned).toEqual(own)
    expect(() => entryOf('exec-1', '/work/api')).toThrow()
    expect(runFolderOf('exec-1')).toBe('/work/web')
    snapshots.length = 0
    await move('/work/api')
    expect(snapshots).toEqual(['/work/api head'])
    expect(entryOf('exec-1', '/work/api').key).not.toBe(before)
  })

  it('and a move to it while it is being taken off takes a start with refs of its own', async () => {
    const { transport, move, add, unpinned } = movingWorld()
    await add('/work/api')
    const before = entryOf('exec-1', '/work/api').key
    const removed = removeRunRepository(transport, 'exec-1', '/work/api')
    expect(await move('/work/api')).toBeNull()
    await removed
    expect(runFolderOf('exec-1')).toBe('/work/api')
    const { key } = entryOf('exec-1', '/work/api')
    expect(key).not.toBe(before)
    expect(unpinned.filter((one) => one.includes(key))).toEqual([])
  })

  it('does not take off a folder moved to, which is not added', async () => {
    const { transport, move, unpinned } = movingWorld()
    await move('/work/api')
    await move('/work/web')
    for (const folder of ['/work/api', '/work/web'])
      await removeRunRepository(transport, 'exec-1', folder)
    expect(unpinned).toEqual([])
    expect(stored('exec-1')?.movedTo).toHaveLength(2)
  })
})

describe('the folders a run’s view was moved to, at the run’s end and after', () => {
  it('have their ends pinned once, shown or not, and a later one at the next call', async () => {
    const { transport, move, pinned } = movingWorld(['/work/api', '/work/web', '/work/db', RUN_DIR])
    await move('/work/api')
    await move('/work/web')
    pinned.length = 0
    await endRunRepositories(transport, 'exec-1')
    expect(pinned).toEqual([
      `/work/api ${ref('exec-1', '/work/api', 'end')}=${WORK}`,
      `/work/web ${ref('exec-1', '/work/web', 'end')}=${WORK}`,
    ])
    expect(entryOf('exec-1', '/work/api').end).toBe(WORK)
    expect(runFolderOf('exec-1')).toBe('/work/web')
    await move('/work/db')
    pinned.length = 0
    expect(entryOf('exec-1', '/work/db').end).toBeNull()
    await endRunRepositories(transport, 'exec-1')
    expect(pinned).toEqual([`/work/db ${ref('exec-1', '/work/db', 'end')}=${WORK}`])
    await endRunRepositories(transport, 'exec-1')
    expect(pinned).toHaveLength(1)
    expect(addedFolders()).toEqual([])
  })

  it('are all unpinned, and the choice forgotten, when the run’s record is gone', async () => {
    const { transport, move, add, unpinned } = movingWorld(['/work/api', '/work/web', '/work/db'])
    await add('/work/db')
    await move('/work/api')
    await move('/work/web')
    const own = refsOf('exec-1', '/work/db', '/work/api', '/work/web')
    await forgetGoneRuns(transport, RECORDS, ['exec-1'])
    expect(unpinned).toEqual([])
    await forgetGoneRuns(transport, RECORDS, [])
    expect(unpinned).toEqual(own)
    expect(runFolderOf('exec-1')).toBeNull()
    rereadRunRepositories()
    expect(runFolderOf('exec-1')).toBeNull()
    expect(stored('exec-1')).toBeUndefined()
  })
})

describe('the folders a run’s changes are read from', () => {
  const START = '3333333333333333333333333333333333333333'
  const END = '4444444444444444444444444444444444444444'
  // What a run that has ended recorded of its own folder.
  const own = { directory: RUN_DIR, start: START, end: END }
  const recorded = { folder: RUN_DIR, start: START, end: END }
  const kept = (folder: string, end: string | null = null) => ({ folder, start: HEAD, end })

  it('are the run’s own and then the added ones when the view was not moved', async () => {
    const { transport } = movingWorld()
    expect(runFoldersShown('exec-1', own)).toEqual([recorded])
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/web')
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    expect(runFoldersShown('exec-1', own)).toEqual([recorded, kept('/work/web'), kept('/work/api')])
    expect(runFoldersShown('exec-2', own)).toEqual([recorded])
  })

  it('are the folder moved to and then the added ones, without the run’s own', async () => {
    const { transport } = movingWorld(['/work/api', '/work/web', '/work/left', RUN_DIR])
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/web')
    await moveRunFolder(transport, 'exec-1', RUN_DIR, '/work/left')
    await moveRunFolder(transport, 'exec-1', RUN_DIR, '/work/api')
    expect(runFoldersShown('exec-1', own)).toEqual([kept('/work/api'), kept('/work/web')])
    expect(runFoldersShown('exec-2', own)).toEqual([recorded])
  })

  it('include the folder moved to when the run pinned no start in its own', async () => {
    const { transport } = movingWorld()
    const unpinned = { directory: RUN_DIR, start: null, end: null }
    expect(runFoldersShown('exec-1', unpinned)).toEqual([])
    await moveRunFolder(transport, 'exec-1', RUN_DIR, '/work/api')
    expect(runFoldersShown('exec-1', unpinned)).toEqual([kept('/work/api')])
  })

  it('give a folder moved to no end of the run’s own, only the one pinned in it', async () => {
    const { transport } = movingWorld()
    await moveRunFolder(transport, 'exec-1', RUN_DIR, '/work/api')
    // No end: it is read to the working tree.
    expect(runFoldersShown('exec-1', own)).toEqual([kept('/work/api')])
    await endRunRepositories(transport, 'exec-1')
    expect(runFoldersShown('exec-1', own)).toEqual([kept('/work/api', WORK)])
  })

  it('are the recorded trees again after going back to the run’s own folder', async () => {
    const { transport } = movingWorld()
    await moveRunFolder(transport, 'exec-1', RUN_DIR, '/work/api')
    await endRunRepositories(transport, 'exec-1')
    await moveRunFolder(transport, 'exec-1', RUN_DIR, `${RUN_DIR}/`)
    expect(runFoldersShown('exec-1', own)).toEqual([recorded])
  })

  it('hold no folder twice', async () => {
    const { transport } = movingWorld()
    const folders = () => runFoldersShown('exec-1', own).map((one) => one.folder)
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    await moveRunFolder(transport, 'exec-1', RUN_DIR, '/work/api/')
    expect(folders()).toEqual(['/work/api'])
    await moveRunFolder(transport, 'exec-1', RUN_DIR, '/work/web')
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    expect(folders()).toEqual(['/work/web', '/work/api'])
  })

  it('never list the run’s own folder as an added one, however the record writes it', async () => {
    const { transport } = movingWorld()
    // Added while the run was told no folder, so nothing refused it.
    await addRunRepository(transport, 'exec-1', null, RUN_DIR)
    const slashed = { ...own, directory: `${RUN_DIR}/` }
    expect(runFoldersShown('exec-1', slashed)).toEqual([{ ...recorded, folder: `${RUN_DIR}/` }])
    await moveRunFolder(transport, 'exec-1', RUN_DIR, '/work/api')
    expect(runFoldersShown('exec-1', slashed)).toEqual([kept('/work/api')])
  })
})
