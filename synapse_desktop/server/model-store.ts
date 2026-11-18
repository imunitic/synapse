// The models of each harness, kept on disk between runs of the app. A list is read from a harness
// by running it, which takes seconds for some, so the app answers from what it kept, reads the
// three again in the background when it starts, and reads one again when it is old or when it is
// asked to. A list that could not be read never replaces one that could.

import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { z } from 'zod'
import type { Harness, ModelCatalog } from '../shared/transport.ts'
import { readModels, type ModelDeps } from './models.ts'
import type { Environment } from './roots.ts'

const HARNESSES: readonly Harness[] = ['Claude', 'Codex', 'Opencode']

// How old a list may be before it is read again when it is asked for. The app reads them all anew
// whenever it starts, so this is for an app that is left open.
const MAX_AGE_MS = 6 * 60 * 60 * 1000

const storedSchema = z.object({
  version: z.literal(1),
  harnesses: z.partialRecord(
    z.enum(['Claude', 'Codex', 'Opencode']),
    z.object({
      at: z.number(),
      models: z.array(
        z.object({
          id: z.string(),
          provider: z.string().nullable(),
          available: z.boolean(),
          detail: z.string().nullable(),
        }),
      ),
      note: z.string().nullable(),
    }),
  ),
})

type Entry = z.infer<typeof storedSchema>['harnesses'][Harness] & object

// The file is a cache, so it is in the folder of caches: `$XDG_CACHE_HOME`, else `~/.cache`.
export function modelCacheFile({ env, home }: Environment): string {
  return join(env.XDG_CACHE_HOME || join(home, '.cache'), 'synapse-desktop', 'models.json')
}

export interface ModelStore {
  // What is kept for the harness, at once, when something is; else what a read of it gives.
  list(harness: Harness): Promise<ModelCatalog>
  // Reads the list from the harness now. When that gives nothing, what was kept stays.
  refresh(harness: Harness): Promise<ModelCatalog>
  // Reads the lists of all three, as the app does when it starts.
  refreshAll(): Promise<void>
}

export interface ModelStoreDeps extends ModelDeps {
  file: string
  now?: () => number
  // How the models of a harness are read; the programs themselves unless a test gives another.
  read?: (harness: Harness) => Promise<ModelCatalog>
}

export function createModelStore(deps: ModelStoreDeps): ModelStore {
  const now = deps.now ?? Date.now
  const read = deps.read ?? ((harness) => readModels(harness, deps))
  const entries = new Map<Harness, Entry>()
  let loaded: Promise<void> | null = null
  // A read that is going on is joined and not started again.
  const reading = new Map<Harness, Promise<ModelCatalog>>()
  // The writes of the file go one after the other, since each is of all the lists.
  let writing: Promise<void> = Promise.resolve()

  function load(): Promise<void> {
    loaded ??= (async () => {
      try {
        const parsed = storedSchema.safeParse(JSON.parse(await readFile(deps.file, 'utf8')))
        if (!parsed.success) return
        for (const harness of HARNESSES) {
          const entry = parsed.data.harnesses[harness]
          if (entry !== undefined && entry.models.length > 0) entries.set(harness, entry)
        }
      } catch {
        // No file, or one that is not this: the lists are read.
      }
    })()
    return loaded
  }

  function save(): Promise<void> {
    writing = writing.then(async () => {
      const harnesses = Object.fromEntries(entries)
      const temporary = `${deps.file}.${process.pid}.tmp`
      try {
        await mkdir(dirname(deps.file), { recursive: true })
        await writeFile(temporary, JSON.stringify({ version: 1, harnesses }))
        await rename(temporary, deps.file)
      } catch {
        // What cannot be kept is read again next time.
      }
    })
    return writing
  }

  const catalogOf = (entry: Entry): ModelCatalog => ({
    models: entry.models,
    note: entry.note,
    readAt: new Date(entry.at).toISOString(),
  })

  function refresh(harness: Harness): Promise<ModelCatalog> {
    const going = reading.get(harness)
    if (going !== undefined) return going
    const started = (async (): Promise<ModelCatalog> => {
      await load()
      const catalog = await read(harness).catch((): ModelCatalog => ({
        models: [],
        note: null,
        readAt: null,
      }))
      const kept = entries.get(harness)
      if (catalog.models.length === 0) {
        // Nothing was read: what was kept is still the best there is.
        return kept === undefined ? catalog : catalogOf(kept)
      }
      const entry: Entry = { at: now(), models: catalog.models, note: catalog.note }
      entries.set(harness, entry)
      await save()
      return catalogOf(entry)
    })().finally(() => reading.delete(harness))
    reading.set(harness, started)
    return started
  }

  return {
    async list(harness) {
      await load()
      const kept = entries.get(harness)
      if (kept === undefined) return refresh(harness)
      // Old, it is read again behind the answer.
      if (now() - kept.at > MAX_AGE_MS) void refresh(harness)
      return catalogOf(kept)
    },
    refresh,
    async refreshAll() {
      await Promise.all(HARNESSES.map((harness) => refresh(harness)))
    },
  }
}
