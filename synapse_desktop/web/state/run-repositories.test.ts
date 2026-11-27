import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Snapshot } from '../../shared/changes.ts'
import { fakeTransport } from '../domain/fake-transport.ts'
import { memoryStorage } from './memory-storage.ts'
import {
  addRunRepository,
  endRunRepositories,
  forgetGoneRuns,
  onRunRepositoriesChange,
  removeRunRepository,
  rereadRunRepositories,
  runRepositoriesOf,
} from './run-repositories.ts'

const HEAD = '1111111111111111111111111111111111111111'
const WORK = '2222222222222222222222222222222222222222'
const KEY = 'synapse-desktop.run-repositories'
const RUN_DIR = '/work/run'
const RECORDS = '/work/.synapse/executions'

const NOT_ROOT = 'the folder is not the root of a git repository'

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
    expect(pinned).toEqual([`/work/api runs/exec-1/start=${HEAD}`])
    expect(runRepositoriesOf('exec-1')).toEqual([
      { folder: '/work/api', records: RECORDS, start: HEAD, end: null },
    ])
    expect(runRepositoriesOf('exec-2')).toEqual([])
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
    expect(pinned).toEqual([`${nested} runs/exec-1/start=${HEAD}`])
    expect(runRepositoriesOf('exec-1').map((one) => one.folder)).toEqual([nested])
  })

  it('is added from inside the run’s folder when that folder is a repository itself (a home folder in git)', async () => {
    const home = '/Users/me'
    const { transport, pinned } = world([home, `${home}/work/api`])
    expect(await addRunRepository(transport, 'exec-1', home, `${home}/work/api`)).toBeNull()
    expect(pinned).toEqual([`${home}/work/api runs/exec-1/start=${HEAD}`])
  })

  it('is added from inside the run’s folder when that folder is not in a repository', async () => {
    const home = '/Users/me'
    const { transport, pinned } = world([`${home}/work/api`])
    expect(await addRunRepository(transport, 'exec-1', home, `${home}/work/api`)).toBeNull()
    expect(pinned).toEqual([`${home}/work/api runs/exec-1/start=${HEAD}`])
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
    expect(runRepositoriesOf('exec-1')).toEqual([
      { folder: '/work/api', records: RECORDS, start: HEAD, end: null },
    ])
    expect(JSON.parse(localStorage.getItem(KEY) ?? '{}')).toEqual({
      'exec-1': [{ folder: '/work/api', records: RECORDS, start: HEAD, end: null }],
    })
  })
})

describe('a repository taken off a run', () => {
  it('has both refs unpinned and is forgotten; the others stay', async () => {
    const { transport, unpinned } = world()
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/api')
    await addRunRepository(transport, 'exec-1', RUN_DIR, '/work/web')
    await removeRunRepository(transport, 'exec-1', '/work/api')
    expect(unpinned).toEqual(['/work/api runs/exec-1/start', '/work/api runs/exec-1/end'])
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
      `/work/api runs/exec-1/end=${WORK}`,
      `/work/web runs/exec-1/end=${WORK}`,
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
    expect(pinned).toEqual([`/work/api runs/exec-1/end=${WORK}`])
    expect(runRepositoriesOf('exec-1')[0]?.end).toBe(WORK)
  })
})

describe('a run whose record is gone', () => {
  it('has both refs unpinned in each of its repositories and is forgotten; a known one is kept', async () => {
    const { transport, unpinned } = world()
    await addRunRepository(transport, 'gone', RUN_DIR, '/work/api')
    await addRunRepository(transport, 'gone', RUN_DIR, '/work/web')
    await addRunRepository(transport, 'known', RUN_DIR, '/work/api')
    await forgetGoneRuns(transport, RECORDS, ['known', 'other'])
    expect(unpinned).toEqual([
      '/work/api runs/gone/start',
      '/work/api runs/gone/end',
      '/work/web runs/gone/start',
      '/work/web runs/gone/end',
    ])
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
