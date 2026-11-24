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

// The fake, with what a test reads of it: the runs that were stopped, and a way to publish a line
// to the watchers of a run.
export interface FakeTransport extends Transport {
  stoppedRuns: string[]
  emitRunLine(run: string, line: string): void
}

function unavailable(): never {
  throw new Error('not used by the tests')
}

export function fakeTransport(world: FakeWorld): FakeTransport {
  const stoppedRuns: string[] = []
  const watchers = new Map<string, Set<(line: string) => void>>()
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
    stoppedRuns,
    emitRunLine(run, line) {
      for (const onLine of watchers.get(run) ?? []) onLine(line)
    },
    stopAgentRun(run) {
      stoppedRuns.push(run)
      return Promise.resolve()
    },
    watchNoteRun(run, onLine) {
      const held = watchers.get(run) ?? new Set()
      held.add(onLine)
      watchers.set(run, held)
      return () => held.delete(onLine)
    },
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
    deleteDefinition: unavailable,
    snapshotChanges: unavailable,
    diffChanges: unavailable,
    listCommits: unavailable,
    commitChanges: unavailable,
    generateDefinition: unavailable,
    createNote: unavailable,
    editNote: unavailable,
    restoreNote: unavailable,
    setNoteStatus: unavailable,
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
    listTerminals: unavailable,
    closeTerminal: unavailable,
    getConfig: (): Promise<AppConfig> => unavailable(),
    setConfig: unavailable,
  }
}
