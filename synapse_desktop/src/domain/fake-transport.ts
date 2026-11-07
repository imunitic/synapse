// An in-memory Transport for tests: files by path, and the runs that answer.

import type { AppConfig, AppPaths, DirEntry, RunAnswer, Transport } from '../../shared/transport.ts'

export interface FakeWorld {
  files: Record<string, string>
  paths: AppPaths
  // Ids of the runs that answer on their socket.
  listening?: string[]
}

function unavailable(): never {
  throw new Error('not used by the tests')
}

export function fakeTransport(world: FakeWorld): Transport {
  const paths = Object.keys(world.files)

  function readDir(dir: string): Promise<DirEntry[]> {
    const prefix = dir.endsWith('/') ? dir : `${dir}/`
    const names = new Map<string, boolean>()
    for (const path of paths) {
      if (!path.startsWith(prefix)) continue
      const rest = path.slice(prefix.length)
      const slash = rest.indexOf('/')
      names.set(slash === -1 ? rest : rest.slice(0, slash), slash !== -1)
    }
    if (names.size === 0) return Promise.reject(new Error('not found'))
    return Promise.resolve([...names].map(([name, isDir]) => ({ name, isDir, mtimeMs: 0 })))
  }

  return {
    readText(path) {
      const text = world.files[path]
      return text === undefined ? Promise.reject(new Error('not found')) : Promise.resolve(text)
    },
    readDir,
    getPaths: () => Promise.resolve(world.paths),
    runRequest(id): Promise<RunAnswer> {
      return world.listening?.includes(id)
        ? Promise.resolve({ ok: true, result: {} })
        : Promise.reject(new Error('the run is not listening'))
    },
    watch: unavailable,
    cli: unavailable,
    startRun: unavailable,
    stopRun: unavailable,
    previewDraft: unavailable,
    writeDefinition: unavailable,
    saveDefinition: unavailable,
    generateDefinition: unavailable,
    getConfig: (): Promise<AppConfig> => unavailable(),
    setConfig: unavailable,
  }
}
