// The handler of each message of the Node host: each reaches only what the roots and the CLI
// allowlist let it.

import { mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { isAbsolute, join } from 'node:path'
import { ZodError } from 'zod'
import { appConfigSchema } from '../shared/calls.ts'
import { HostError, type Handlers as DispatchHandlers } from '../shared/dispatch.ts'
import { messages, type MessageName, type Params, type Result } from '../shared/messages.ts'
import type { AppConfig, AppPaths, CliResult, DirEntry, Harness } from '../shared/transport.ts'
import { cliEnvironment, refuseCli, type CliRunner } from './cli.ts'
import { findGraphRepos } from './graph-find.ts'
import { expandConfigPaths, expandHome } from './home.ts'
import { checkGraphRepo, graphHealth } from './graph-health.ts'
import { cleanGraphs, dropGraph, planGraphClean, planGraphDrop } from './graph-manage.ts'
import { findContentRoot } from './inject.ts'
import { inspectIntegrations, versionOfProgram } from './integrations.ts'
import { loadConfig, loadStoredConfig, saveConfig } from './config-store.ts'
import {
  allowedRoots,
  definitionDirs as listDefinitionDirs,
  existingDirs,
  OutsideRoots,
  pipelineConfigDir,
  resolveInside,
  type Environment,
} from './roots.ts'
import { GenerationFailed, generateText, SkillNotFound, type AgentRunner } from './generate.ts'
import {
  createdPath,
  NoteFailed,
  notePrompt,
  pathsOf,
  reasonOf,
  vaultDirOf,
  type NoteSession,
} from './note-agent.ts'
import {
  changesSince,
  commitChanges,
  commitLog,
  headPosition,
  headTree,
  pinSnapshot,
  snapshotTree,
  unpinSnapshot,
} from './changes.ts'
import { previewDraft } from './preview.ts'
import { editNote, restoreNote, setNoteStatus } from './note-edit.ts'
import {
  addConvention,
  type ProjectsSource,
  listConventions,
  removeConvention,
} from './conventions.ts'
import { addProject, listProjects, loadProjects } from './projects.ts'
import { inspectVault, seedVault } from './vault.ts'
import { diagnose } from './doctor.ts'
import { histories, listSessions, listWorkspaces } from './history/history.ts'
import { createModelStore, modelCacheFile, type ModelStore } from './model-store.ts'
import { askRun, NotListening, socketPath } from './run-socket.ts'
import type { NoteRunHandle, NoteRuns } from './note-runs.ts'
import { FolderNotFound, NotStartedHere, RunNotStarted, type RunStarter } from './runs.ts'
import type { Usage } from './usage.ts'

const MAX_FILE_BYTES = 4 * 1024 * 1024

export interface Context {
  environment: Environment
  configFile: string
  runCli: CliRunner
  runs: RunStarter
  agent: AgentRunner
  // Runs a headless session of a harness with Synapse loaded, to write a note.
  noteSession: NoteSession
  // The runs of an agent that a client can watch and stop.
  noteRuns: NoteRuns
  // The models of the harnesses, kept between runs. One is made when there is none.
  models?: ModelStore
  // The usage of the harnesses, published on the `usage` topic. Without it the topic says nothing.
  usage?: Usage
}

// The store of a context that was not given one, made once for it.
const stores = new WeakMap<Context, ModelStore>()

function modelsOf(context: Context): ModelStore {
  if (context.models !== undefined) return context.models
  let store = stores.get(context)
  if (store === undefined) {
    store = createModelStore({
      file: modelCacheFile(context.environment),
      env: context.environment.env,
    })
    stores.set(context, store)
  }
  return store
}

// A headless session of a harness for a note of the vault: it runs in the environment
// the app runs programs in and may write in the vault and where the skills keep their
// files. The prompt is given when it is run.
async function noteSessionOf(
  context: Context,
  config: AppConfig,
  harness: Harness,
  model: string | undefined,
): Promise<(prompt: string, extra?: NoteSessionExtra) => Promise<CliResult>> {
  const settings = await context.runCli({
    binary: 'synapse',
    args: ['config', 'list', '--format', 'json'],
    config,
  })
  const vault = vaultDirOf(settings.stdout)
  if (vault === null) throw new HostError('conflict', 'no vault is set up to write the note in')
  const env = Object.fromEntries(
    Object.entries(cliEnvironment(context.environment.env, config)).filter(
      (entry): entry is [string, string] => entry[1] !== undefined,
    ),
  )
  const writable = await existingDirs([
    vault,
    join(context.environment.home, '.config', 'synapse'),
    config.workDir ?? join(context.environment.home, '.cache', 'synapse', 'work'),
  ])
  return (prompt, extra) =>
    context.noteSession({
      harness,
      prompt,
      env,
      writable,
      ...(model === undefined ? {} : { model }),
      ...(extra?.signal === undefined ? {} : { signal: extra.signal }),
      ...(extra?.onLine === undefined ? {} : { onLine: extra.onLine }),
    })
}

// What a caller adds to a session: a way to stop it and where to send what it prints.
interface NoteSessionExtra {
  signal?: AbortSignal
  onLine?: (line: string) => void
}

// The run a request names, started in the registry; none when the request has no id. The run is
// finished by the caller when the session ends.
function startRun(
  request: { run?: string | undefined },
  context: Context,
): NoteRunHandle | undefined {
  return request.run === undefined ? undefined : context.noteRuns.start(request.run)
}

async function insideRoots(path: string, context: Context): Promise<string> {
  const config = await loadConfig(context.configFile, context.environment)
  try {
    return await resolveInside(path, allowedRoots(config, context.environment))
  } catch (error) {
    if (error instanceof OutsideRoots) throw new HostError('forbidden', error.message)
    throw error
  }
}

async function pathsOf_(context: Context): Promise<AppPaths> {
  const config = await loadConfig(context.configFile, context.environment)
  const { environment } = context
  const [recordsDir] = await existingDirs(
    config.workDir === null ? [] : [join(config.workDir, 'pipelines')],
  )
  return {
    definitionDirs: await existingDirs(listDefinitionDirs(config, environment)),
    recordsDir: recordsDir ?? null,
  }
}

// Where the projects are asked: `synapse projects`, run as the app runs the programs.
async function projectsOf(context: Context): Promise<ProjectsSource> {
  const config = await loadConfig(context.configFile, context.environment)
  return {
    load: () => loadProjects(context.runCli, config),
    add: (name, prefix) => addProject(context.runCli, config, name, prefix),
  }
}

// What a request is answered with, from its validated parameters and the context: a refusal is a
// HostError with its code.
// The messages these handlers answer: the terminals are served by the sessions of the connection.
export type CallMessage = Exclude<MessageName, `terminal.${string}`>

type Handlers = {
  [N in CallMessage]: (params: Params<N>, context: Context) => Promise<Result<N>>
}

// The real path of a definition file, only where definitions live: not the records of runs.
async function definitionFile(
  path: string,
  context: Context,
  what: 'saved' | 'removed',
): Promise<string> {
  if (!path.endsWith('.synapse')) {
    throw new HostError('bad_request', `only a definition can be ${what}`)
  }
  const config = await loadConfig(context.configFile, context.environment)
  try {
    return await resolveInside(path, listDefinitionDirs(config, context.environment))
  } catch (error) {
    if (error instanceof OutsideRoots) throw new HostError('forbidden', error.message)
    throw error
  }
}

const handlers: Handlers = {
  async 'fs.read'({ path }, context) {
    const real = await insideRoots(path, context)
    const { size } = await stat(real)
    if (size > MAX_FILE_BYTES) throw new HostError('too_large', 'file is too large')
    return { text: await readFile(real, 'utf8') }
  },

  async 'fs.list'({ path }, context) {
    const real = await insideRoots(path, context)
    const entries = await readdir(real, { withFileTypes: true })
    const result: DirEntry[] = []
    for (const entry of entries) {
      // A link that leads nowhere has no modification time to report.
      const info = await stat(join(real, entry.name)).catch(() => null)
      result.push({
        name: entry.name,
        isDir: info?.isDirectory() ?? false,
        mtimeMs: info?.mtimeMs ?? 0,
      })
    }
    return { entries: result.sort((a, b) => a.name.localeCompare(b.name)) }
  },

  async cli({ binary, args, stdin }, context) {
    const refusal = refuseCli(binary, args)
    if (refusal !== null) throw new HostError('bad_request', refusal)
    const config = await loadConfig(context.configFile, context.environment)
    return context.runCli({ binary, args, stdin, config })
  },

  async 'config.get'(_params, context) {
    return {
      config: await loadConfig(context.configFile, context.environment),
      paths: await pathsOf_(context),
    }
  },

  async 'config.set'({ patch }, context) {
    const merged = expandConfigPaths(
      appConfigSchema.parse({
        ...(await loadStoredConfig(context.configFile)),
        ...patch,
      }),
      context.environment.home,
    )
    await saveConfig(context.configFile, merged)
    return {
      config: await loadConfig(context.configFile, context.environment),
      paths: await pathsOf_(context),
    }
  },

  async 'registry.list'({ kind }, context) {
    const projects = await projectsOf(context)
    return kind === 'projects'
      ? { kind, list: await projects.load() }
      : { kind, list: await listConventions(context.environment, projects) }
  },

  async 'registry.add'(params, context) {
    const projects = await projectsOf(context)
    return params.kind === 'projects'
      ? { kind: params.kind, list: await projects.add(params.name, params.prefix) }
      : {
          kind: params.kind,
          list: await addConvention(context.environment, projects, params.id, params.entry),
        }
  },

  async 'registry.remove'({ kind, id, entry }, context) {
    const projects = await projectsOf(context)
    return { kind, list: await removeConvention(context.environment, projects, id, entry) }
  },

  async 'models.get'({ harness, refresh }, context) {
    const store = modelsOf(context)
    return refresh === true ? store.refresh(harness) : store.list(harness)
  },

  async 'history.get'({ what }, context) {
    return what === 'sessions'
      ? { what, sessions: await listSessions(histories(context.environment)) }
      : { what, workspaces: await listWorkspaces(histories(context.environment)) }
  },

  async 'agent.run'(request, context) {
    switch (request.kind) {
      case 'definition': {
        const { defaultHarness, defaultModels, env } = await loadConfig(
          context.configFile,
          context.environment,
        )
        const harness = request.harness ?? defaultHarness ?? 'Claude'
        const model = request.model ?? defaultModels[harness]
        const handle = startRun(request, context)
        try {
          const text = await generateText(
            {
              kind: request.what,
              prompt: request.prompt,
              ...(request.current === undefined ? {} : { current: request.current }),
              definitions: request.definitions,
            },
            {
              harness,
              ...(model === undefined ? {} : { model }),
              env,
              pathVariable: context.environment.env.PATH ?? '',
              agent: context.agent,
              ...(handle === undefined ? {} : { signal: handle.signal }),
            },
          )
          return { kind: 'definition', text }
        } catch (error) {
          if (error instanceof SkillNotFound) throw new HostError('conflict', error.message)
          if (error instanceof GenerationFailed) throw new HostError('unavailable', error.message)
          throw error
        } finally {
          handle?.finish()
        }
      }
      case 'note':
        return { kind: 'note', path: await createNoteFrom(request, context) }
      case 'note-edit': {
        const config = await loadConfig(context.configFile, context.environment)
        const harness = request.harness ?? config.defaultHarness ?? 'Claude'
        const session = await noteSessionOf(
          context,
          config,
          harness,
          request.model ?? config.defaultModels[harness],
        )
        const handle = startRun(request, context)
        try {
          const edit = await editNote(
            {
              run: context.runCli,
              config,
              harness,
              session: (prompt) =>
                session(prompt, {
                  ...(handle === undefined ? {} : { signal: handle.signal }),
                  ...(handle === undefined || harness !== 'Claude'
                    ? {}
                    : { onLine: handle.publish }),
                }),
              ...(handle === undefined ? {} : { stopped: handle.stopped }),
            },
            request.path,
            request.prompt,
          )
          return { kind: 'note-edit', edit }
        } finally {
          handle?.finish()
        }
      }
    }
  },

  async 'agent.stop'({ run }, context) {
    context.noteRuns.stop(run)
    return null
  },

  async 'note.restore'({ path, before, after }, context) {
    const config = await loadConfig(context.configFile, context.environment)
    // The note is checked against the vault's schemas, which are in the Synapse package.
    const contentRoot = await findContentRoot(cliEnvironment(context.environment.env, config))
    await restoreNote(context.runCli, config, path, before, after, contentRoot)
    return null
  },

  async 'note.status'({ path, status }, context) {
    const config = await loadConfig(context.configFile, context.environment)
    // The program checks the note against the vault's schemas, which are in the Synapse package.
    const contentRoot = await findContentRoot(cliEnvironment(context.environment.env, config))
    await setNoteStatus(context.runCli, config, path, status, contentRoot)
    return null
  },

  async 'definition.preview'({ draft }, context) {
    return previewDraft(draft, context)
  },

  async 'definition.write'(item, context) {
    if (item.mode === 'delete') {
      const { path } = item
      await rm(await definitionFile(path, context, 'removed'))
      return { path }
    }
    if (item.mode === 'replace') {
      const { path, previous, text } = item
      const real = await definitionFile(path, context, 'saved')
      if ((await readFile(real, 'utf8')) !== previous) {
        throw new HostError('conflict', 'the file has changed since it was read')
      }
      await writeFile(real, text)
      return { path }
    }
    const defaultDir = pipelineConfigDir(context.environment)
    const path = join(defaultDir, `${item.name}.synapse`)
    await mkdir(defaultDir, { recursive: true })
    try {
      // `wx` fails when the file is there: a definition is never replaced.
      await writeFile(path, item.text, { flag: 'wx' })
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'EEXIST') {
        throw new HostError('conflict', `${item.name} already exists`)
      }
      throw error
    }
    return { path }
  },

  async 'changes.snapshot'({ folder, of }) {
    if (!isAbsolute(folder)) throw new HostError('bad_request', 'the folder must be absolute')
    const tree = of === 'head' ? await headTree(folder) : await snapshotTree(folder)
    return { tree, head: tree === null ? null : await headPosition(folder) }
  },

  async 'changes.diff'({ folder, before, path, after }) {
    if (!isAbsolute(folder)) throw new HostError('bad_request', 'the folder must be absolute')
    return changesSince(folder, before, path, after)
  },

  async 'changes.pin'({ folder, ref, tree }) {
    if (!isAbsolute(folder)) throw new HostError('bad_request', 'the folder must be absolute')
    await pinSnapshot(folder, ref, tree)
    return null
  },

  async 'changes.unpin'({ folder, ref }) {
    if (!isAbsolute(folder)) throw new HostError('bad_request', 'the folder must be absolute')
    await unpinSnapshot(folder, ref)
    return null
  },

  async 'changes.log'({ folder, limit, before }) {
    if (!isAbsolute(folder)) throw new HostError('bad_request', 'the folder must be absolute')
    return commitLog(folder, limit, before)
  },

  async 'changes.commit'({ folder, commit, path }) {
    if (!isAbsolute(folder)) throw new HostError('bad_request', 'the folder must be absolute')
    return commitChanges(folder, commit, path)
  },

  async 'run.start'({ pipeline, input, folder, runName }, context) {
    const config = await loadConfig(context.configFile, context.environment)
    try {
      return await context.runs.start(pipeline, input, config, folder, runName)
    } catch (error) {
      if (error instanceof FolderNotFound) throw new HostError('bad_request', error.message)
      if (error instanceof RunNotStarted) {
        throw new HostError(config.workDir === null ? 'conflict' : 'unavailable', error.message)
      }
      throw error
    }
  },

  async 'run.stop'({ executionId }, context) {
    try {
      context.runs.stop(executionId)
    } catch (error) {
      if (error instanceof NotStartedHere) throw new HostError('not_found', error.message)
      throw error
    }
    return null
  },

  async 'run.ask'({ executionId, request }, context) {
    const { workDir } = await loadConfig(context.configFile, context.environment)
    if (workDir === null) throw new HostError('conflict', 'no work directory is set')
    const path = socketPath(join(workDir, 'pipelines'), executionId, process.platform)
    try {
      return await askRun(path, request)
    } catch (error) {
      if (error instanceof NotListening)
        throw new HostError('not_found', 'the run is not listening')
      throw error
    }
  },

  async 'vault.inspect'({ path: typed }, context) {
    const path = expandHome(typed, context.environment.home)
    if (!isAbsolute(path)) throw new HostError('bad_request', 'the path must be absolute')
    return { ...(await inspectVault(path)), path }
  },

  async 'vault.seed'({ path: typed }, context) {
    const path = expandHome(typed, context.environment.home)
    if (!isAbsolute(path)) throw new HostError('bad_request', 'the path must be absolute')
    const config = await loadConfig(context.configFile, context.environment)
    const root = await findContentRoot(cliEnvironment(context.environment.env, config))
    await seedVault(path, root === null ? null : join(root, 'Index.md.template'))
    return { ...(await inspectVault(path)), path }
  },

  async 'graph.repo'(params, context) {
    const config = await loadConfig(context.configFile, context.environment)
    if (params.action === 'check') {
      const check = await checkGraphRepo(
        context.runCli,
        config,
        expandHome(params.path, context.environment.home),
      )
      return { action: 'check', check }
    }
    const paths = await findGraphRepos(context.runCli, config, params.namespace)
    return { action: 'find', matches: { paths } }
  },

  async 'graph.health'({ namespace }, context) {
    const config = await loadConfig(context.configFile, context.environment)
    const repo = config.graphRepos[namespace]
    if (repo === undefined) {
      throw new HostError('conflict', 'no repository is saved for this graph')
    }
    if (!(await stat(repo).catch(() => null))?.isDirectory()) {
      throw new HostError('conflict', `${repo} is not a folder`)
    }
    return graphHealth(context.runCli, config, namespace, repo)
  },

  async 'graph.manage'({ action, what, namespace }, context) {
    const config = await loadConfig(context.configFile, context.environment)
    if (action === 'plan') {
      const plan = await (what === 'drop' ? planGraphDrop : planGraphClean)(
        context.runCli,
        config,
        namespace,
      )
      return { action, plan }
    }
    const done = await (what === 'drop' ? dropGraph : cleanGraphs)(
      context.runCli,
      config,
      namespace,
    )
    return { action, output: done.output }
  },

  async diagnose(_params, context) {
    const config = await loadConfig(context.configFile, context.environment)
    return diagnose(config, { runCli: context.runCli, env: context.environment.env })
  },

  async integrations(_params, context) {
    const config = await loadConfig(context.configFile, context.environment)
    return inspectIntegrations({
      env: cliEnvironment(context.environment.env, config),
      home: context.environment.home,
      versionOf: versionOfProgram,
    })
  },
}

// A note written by an agent: the path of the one the session made.
async function createNoteFrom(
  request: Extract<Params<'agent.run'>, { kind: 'note' }>,
  context: Context,
): Promise<string> {
  const config = await loadConfig(context.configFile, context.environment)
  const harness = request.harness ?? config.defaultHarness ?? 'Claude'
  const session = await noteSessionOf(
    context,
    config,
    harness,
    request.model ?? config.defaultModels[harness],
  )
  // A task or design note belongs to a project, which a request names or the agent
  // matches from the ones there are.
  const projects = await listProjects(context.runCli, config)
  const chosen =
    request.project === undefined
      ? undefined
      : projects.find((project) => project.name === request.project)
  if (request.project !== undefined && chosen === undefined) {
    throw new HostError('conflict', `${request.project} is not a project in synapse-projects.conf`)
  }
  const list = async (): Promise<string[]> => {
    const result = await context.runCli({ binary: 'synapse', args: ['vault-list'], config })
    if (result.code !== 0) {
      throw new HostError('unavailable', result.stderr.trim() || 'the vault could not be listed')
    }
    return pathsOf(result.stdout)
  }
  const before = new Set(await list())
  const handle = startRun(request, context)
  let run: CliResult
  try {
    run = await session(
      notePrompt(request.what, request.prompt, harness, projects, chosen),
      handle === undefined ? undefined : { signal: handle.signal },
    )
  } finally {
    handle?.finish()
  }
  const path = createdPath(run.stdout, before, await list())
  if (path !== null) return path
  if (handle?.stopped() === true) throw new NoteFailed('The run was stopped. No note was written.')
  const why = reasonOf(run.stdout, run.stderr)
  throw new NoteFailed(`No note was written. ${why}`.trim())
}

// Answers one message with its handler, from parameters that are not yet checked: a refusal is a
// HostError with its code. The host checks them itself; this is for what calls a handler directly.
export async function handleMessage<N extends CallMessage>(
  name: N,
  raw: unknown,
  context: Context,
): Promise<Result<N>> {
  let params: Params<N>
  try {
    params = messages[name].params.parse(raw) as Params<N>
  } catch (error) {
    if (error instanceof ZodError)
      throw new HostError('bad_request', `invalid parameters: ${error.message}`)
    throw error
  }
  return handlers[name](params, context)
}

// The handlers as a host serves them, each with the context of the host.
export function hostHandlers(context: Context): DispatchHandlers {
  const served: Record<string, (params: unknown) => Promise<unknown>> = {}
  for (const name of Object.keys(handlers) as (keyof typeof handlers)[]) {
    served[name] = (params) =>
      (handlers[name] as (p: unknown, c: Context) => Promise<unknown>)(params, context)
  }
  return served as DispatchHandlers
}
