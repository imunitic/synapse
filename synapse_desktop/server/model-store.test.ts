import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Harness, ModelCatalog } from '../shared/transport.ts'
import { createModelStore, modelCacheFile } from './model-store.ts'

let dir: string
let file: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-model-store-'))
  file = join(dir, 'cache', 'models.json')
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

const catalog = (...ids: string[]): ModelCatalog => ({
  models: ids.map((id) => ({ id, provider: null, available: true, detail: null })),
  note: null,
  readAt: null,
})

const none: ModelCatalog = { models: [], note: 'could not list', readAt: null }

// A reader of the harnesses that answers what it is given, and counts how often it is asked.
function readers(answers: Partial<Record<Harness, ModelCatalog | (() => Promise<ModelCatalog>)>>) {
  const asked: Harness[] = []
  const read = async (harness: Harness): Promise<ModelCatalog> => {
    asked.push(harness)
    const answer = answers[harness] ?? none
    return typeof answer === 'function' ? answer() : answer
  }
  return { read, asked }
}

describe('the models kept for the harnesses', () => {
  it('are read when nothing is kept, and kept for what is asked next', async () => {
    const { read, asked } = readers({ Claude: catalog('sonnet', 'opus') })
    let clock = 1_000
    const store = createModelStore({ file, read, now: () => clock })
    const first = await store.list('Claude')
    expect(first.models.map((m) => m.id)).toEqual(['sonnet', 'opus'])
    expect(first.readAt).toBe(new Date(1_000).toISOString())
    clock = 5_000
    const second = await store.list('Claude')
    expect(second.models).toHaveLength(2)
    // Not read again, and the time is of the read.
    expect(second.readAt).toBe(new Date(1_000).toISOString())
    expect(asked).toEqual(['Claude'])
  })

  it('are in a file, which a new store answers from at once, with no read', async () => {
    const first = createModelStore({ file, read: readers({ Codex: catalog('gpt-a') }).read })
    await first.list('Codex')
    expect(JSON.parse(await readFile(file, 'utf8')).version).toBe(1)

    // The app is started again: nothing is asked of the harness to answer.
    const { read, asked } = readers({ Codex: catalog('gpt-other') })
    const second = createModelStore({ file, read })
    expect((await second.list('Codex')).models.map((m) => m.id)).toEqual(['gpt-a'])
    expect(asked).toEqual([])
  })

  it('are read again for all three when asked to, behind what was kept', async () => {
    const before = readers({
      Claude: catalog('old'),
      Codex: catalog('old'),
      Opencode: catalog('old'),
    })
    await createModelStore({ file, read: before.read }).refreshAll()

    const { read, asked } = readers({
      Claude: catalog('new-a'),
      Codex: catalog('new-b'),
      Opencode: catalog('new-c'),
    })
    const store = createModelStore({ file, read })
    // What was kept is answered before the new lists are in.
    expect((await store.list('Claude')).models[0]?.id).toBe('old')
    await store.refreshAll()
    expect(asked.sort()).toEqual(['Claude', 'Codex', 'Opencode'])
    expect((await store.list('Claude')).models[0]?.id).toBe('new-a')
    expect((await store.list('Opencode')).models[0]?.id).toBe('new-c')
    expect(JSON.parse(await readFile(file, 'utf8')).harnesses.Codex.models[0].id).toBe('new-b')
  })

  it('stay when a read of them gives nothing, and are not replaced by that', async () => {
    let answer: ModelCatalog = catalog('good')
    const store = createModelStore({ file, read: async () => answer })
    await store.refresh('Claude')
    answer = none
    const again = await store.refresh('Claude')
    expect(again.models.map((m) => m.id)).toEqual(['good'])
    expect(again.readAt).not.toBeNull()
    expect(JSON.parse(await readFile(file, 'utf8')).harnesses.Claude.models[0].id).toBe('good')
    // A read that throws is the same.
    const failing = createModelStore({
      file,
      read: async () => {
        throw new Error('boom')
      },
    })
    expect((await failing.refresh('Claude')).models.map((m) => m.id)).toEqual(['good'])
  })

  it('are said to be missing when there are none and a read gives nothing, and that is not kept', async () => {
    const store = createModelStore({ file, read: async () => none })
    expect(await store.list('Opencode')).toEqual(none)
    await expect(readFile(file, 'utf8')).rejects.toThrow()
    expect(await store.list('Opencode')).toEqual(none)
  })

  it('are read again behind the answer when they are old, and not when they are not', async () => {
    let clock = 0
    // The second read is held until it is let go, so that it is seen to follow the answer.
    let release: () => void = () => undefined
    const gate = new Promise<void>((resolve) => {
      release = resolve
    })
    const asked: string[] = []
    const read = async (): Promise<ModelCatalog> => {
      asked.push('read')
      if (asked.length === 1) return catalog('v1')
      await gate
      return catalog('v2')
    }
    const store = createModelStore({ file, read, now: () => clock })
    await store.list('Claude')
    expect(asked).toHaveLength(1)

    // An hour on: kept, and not read again.
    clock = 60 * 60 * 1000
    expect((await store.list('Claude')).models[0]?.id).toBe('v1')
    expect(asked).toHaveLength(1)

    // Seven hours on: the answer is what was kept, given while the new read is still going.
    clock = 7 * 60 * 60 * 1000
    expect((await store.list('Claude')).models[0]?.id).toBe('v1')
    expect(asked).toHaveLength(2)
    release()
    // Asking now joins the read that is going and gets what it read.
    expect((await store.refresh('Claude')).models[0]?.id).toBe('v2')
    expect(asked).toHaveLength(2)
    expect((await store.list('Claude')).models[0]?.id).toBe('v2')
  })

  it('are read once when asked for at the same time', async () => {
    let release: (c: ModelCatalog) => void = () => undefined
    const slow = new Promise<ModelCatalog>((resolve) => {
      release = resolve
    })
    const { read, asked } = readers({ Claude: () => slow })
    const store = createModelStore({ file, read })
    const together = Promise.all([
      store.list('Claude'),
      store.list('Claude'),
      store.refresh('Claude'),
    ])
    release(catalog('sonnet'))
    const [a, b, c] = await together
    expect([a, b, c].map((x) => x.models[0]?.id)).toEqual(['sonnet', 'sonnet', 'sonnet'])
    expect(asked).toEqual(['Claude'])
  })

  it('are read from nothing when the file is not the file of the store', async () => {
    await mkdirFor(file)
    await writeFile(file, '{"version": 2, "harnesses": {"Claude": 5}}')
    const { read, asked } = readers({ Claude: catalog('sonnet') })
    const store = createModelStore({ file, read })
    expect((await store.list('Claude')).models[0]?.id).toBe('sonnet')
    expect(asked).toEqual(['Claude'])
    await writeFile(file, 'not json')
    const other = createModelStore({ file, read })
    expect((await other.list('Claude')).models[0]?.id).toBe('sonnet')
  })

  it('keep the lists of the three side by side when they are read together', async () => {
    const { read } = readers({ Claude: catalog('c'), Codex: catalog('x'), Opencode: catalog('o') })
    const store = createModelStore({ file, read })
    await store.refreshAll()
    const kept = JSON.parse(await readFile(file, 'utf8')) as { harnesses: Record<string, unknown> }
    expect(Object.keys(kept.harnesses).sort()).toEqual(['Claude', 'Codex', 'Opencode'])
  })
})

async function mkdirFor(path: string): Promise<void> {
  const { mkdir } = await import('node:fs/promises')
  await mkdir(join(path, '..'), { recursive: true })
}

describe('where the models are kept', () => {
  it('is the folder of caches, else the cache folder of the home folder', () => {
    expect(modelCacheFile({ env: { XDG_CACHE_HOME: '/c' }, home: '/h' })).toBe(
      '/c/synapse-desktop/models.json',
    )
    expect(modelCacheFile({ env: {}, home: '/h' })).toBe('/h/.cache/synapse-desktop/models.json')
  })
})
