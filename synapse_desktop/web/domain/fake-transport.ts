// An in-memory Transport for tests: files by path, and the runs that answer.

import type {
  AppConfig,
  AppPaths,
  CliBinary,
  CliOptions,
  CliResult,
  DirEntry,
  RunAnswer,
  Transport,
} from '../../shared/transport.ts'

export interface FakeWorld {
  files: Record<string, string>
  paths: AppPaths
  // Ids of the runs that answer on their socket.
  listening?: string[]
  // What the CLI answers, for a test that runs it.
  cli?: (binary: CliBinary, args: readonly string[], options?: CliOptions) => CliResult
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
    cli: (binary, args, options) =>
      world.cli === undefined ? unavailable() : Promise.resolve(world.cli(binary, args, options)),
    startRun: unavailable,
    stopRun: unavailable,
    previewDraft: unavailable,
    writeDefinition: unavailable,
    saveDefinition: unavailable,
    generateDefinition: unavailable,
    createNote: unavailable,
    editNote: unavailable,
    restoreNote: unavailable,
    listProjects: unavailable,
    addProject: unavailable,
    getDiagnosis: unavailable,
    listWorkspaces: unavailable,
    listSessions: unavailable,
    listModels: unavailable,
    refreshModels: unavailable,
    seedVault: unavailable,
    listConventions: unavailable,
    addConvention: unavailable,
    removeConvention: unavailable,
    inspectVault: unavailable,
    getIntegrations: unavailable,
    checkGraphRepo: unavailable,
    findGraphRepos: unavailable,
    graphHealth: unavailable,
    planGraphDrop: unavailable,
    dropGraph: unavailable,
    planGraphClean: unavailable,
    cleanGraphs: unavailable,
    openTerminal: unavailable,
    getConfig: (): Promise<AppConfig> => unavailable(),
    setConfig: unavailable,
  }
}
