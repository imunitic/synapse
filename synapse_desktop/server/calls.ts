// The API calls: each one validates its own parameters and reaches only what
// the roots and the CLI allowlist let it.

import { mkdir, readdir, readFile, stat, writeFile } from 'node:fs/promises'
import { basename, isAbsolute, join } from 'node:path'
import { ZodError } from 'zod'
import { appConfigSchema, callParams, isCallName, type CallName } from '../shared/calls.ts'
import type {
  AppConfig,
  AppPaths,
  CliResult,
  DirEntry,
  GraphHealth,
  GraphPlan,
  GraphRepoCheck,
  GraphRepoMatches,
  Harness,
  Integrations,
  NoteEdit,
  ConventionList,
  Diagnosis,
  ModelCatalog,
  PastSessions,
  Workspaces,
  ProjectList,
  RunAnswer,
  VaultInfo,
} from '../shared/transport.ts'
import { cliEnvironment, refuseCli, type CliRunner } from './cli.ts'
import { findGraphRepos } from './graph-find.ts'
import { expandConfigPaths, expandHome } from './home.ts'
import { checkGraphRepo, graphHealth } from './graph-health.ts'
import {
  cleanGraphs,
  dropGraph,
  GraphActionRefused,
  planGraphClean,
  planGraphDrop,
} from './graph-manage.ts'
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
import { previewDraft } from './preview.ts'
import { EditRefused, editNote, restoreNote } from './note-edit.ts'
import {
  addConvention,
  ConventionRefused,
  listConventions,
  removeConvention,
} from './conventions.ts'
import { addProject, listProjects, ProjectRefused, projectsFile } from './projects.ts'
import { inspectVault, seedVault, VaultRefused } from './vault.ts'
import { diagnose } from './doctor.ts'
import { histories, listSessions, listWorkspaces } from './history/history.ts'
import { createModelStore, modelCacheFile, type ModelStore } from './model-store.ts'
import { askRun, NotListening, socketPath } from './run-socket.ts'
import { NotStartedHere, RunNotStarted, type RunStarter } from './runs.ts'

const MAX_FILE_BYTES = 4 * 1024 * 1024

export interface Context {
  environment: Environment
  configFile: string
  runCli: CliRunner
  runs: RunStarter
  agent: AgentRunner
  // Runs a headless session of a harness with Synapse loaded, to write a note.
  noteSession: NoteSession
  // The models of the harnesses, kept between runs. One is made when there is none.
  models?: ModelStore
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

// An error with the HTTP status the caller should see.
export class CallError extends Error {
  status: number

  constructor(message: string, status: number) {
    super(message)
    this.status = status
  }
}

// A headless session of a harness for a note of the vault: it runs in the environment
// the app runs programs in and may write in the vault and where the skills keep their
// files. The prompt is given when it is run.
async function noteSessionOf(
  context: Context,
  config: AppConfig,
  harness: Harness,
  model: string | undefined,
): Promise<(prompt: string) => Promise<CliResult>> {
  const settings = await context.runCli({
    binary: 'synapse',
    args: ['config', 'list', '--format', 'json'],
    config,
  })
  const vault = vaultDirOf(settings.stdout)
  if (vault === null) throw new CallError('no vault is set up to write the note in', 409)
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
  return (prompt) =>
    context.noteSession({
      harness,
      prompt,
      env,
      writable,
      ...(model === undefined ? {} : { model }),
    })
}

type Handler = (raw: unknown, context: Context) => Promise<unknown>

// A graph action that was refused is an answer with its own status.
async function refusing<T>(action: () => Promise<T>): Promise<T> {
  try {
    return await action()
  } catch (error) {
    if (error instanceof GraphActionRefused) throw new CallError(error.message, error.status)
    throw error
  }
}

async function insideRoots(path: string, context: Context): Promise<string> {
  const config = await loadConfig(context.configFile, context.environment)
  try {
    return await resolveInside(path, allowedRoots(config, context.environment))
  } catch (error) {
    if (error instanceof OutsideRoots) throw new CallError(error.message, 403)
    throw error
  }
}

const handlers: Record<CallName, Handler> = {
  async readText(raw, context): Promise<string> {
    const { path } = callParams.readText.parse(raw)
    const real = await insideRoots(path, context)
    const { size } = await stat(real)
    if (size > MAX_FILE_BYTES) throw new CallError('file is too large', 413)
    return readFile(real, 'utf8')
  },

  async readDir(raw, context): Promise<DirEntry[]> {
    const { path } = callParams.readDir.parse(raw)
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
    return result.sort((a, b) => a.name.localeCompare(b.name))
  },

  async cli(raw, context): Promise<CliResult> {
    const { binary, args, stdin } = callParams.cli.parse(raw)
    const refusal = refuseCli(binary, args)
    if (refusal !== null) throw new CallError(refusal, 400)
    const config = await loadConfig(context.configFile, context.environment)
    return context.runCli({ binary, args, stdin, config })
  },

  async runRequest(raw, context): Promise<RunAnswer> {
    const { executionId, request } = callParams.runRequest.parse(raw)
    const { workDir } = await loadConfig(context.configFile, context.environment)
    if (workDir === null) throw new CallError('no work directory is set', 409)
    const path = socketPath(join(workDir, 'pipelines'), executionId, process.platform)
    try {
      return await askRun(path, request)
    } catch (error) {
      if (error instanceof NotListening) throw new CallError('the run is not listening', 404)
      throw error
    }
  },

  async getPaths(raw, context): Promise<AppPaths> {
    callParams.getPaths.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    const { environment } = context
    const [skillsDir] = await existingDirs([join(pipelineConfigDir(environment), 'skills')])
    const [recordsDir] = await existingDirs(
      config.workDir === null ? [] : [join(config.workDir, 'pipelines')],
    )
    return {
      definitionDirs: await existingDirs(listDefinitionDirs(config, environment)),
      skillsDir: skillsDir ?? null,
      recordsDir: recordsDir ?? null,
    }
  },

  async startRun(raw, context): Promise<{ executionId: string }> {
    const { pipeline, input } = callParams.startRun.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    try {
      return await context.runs.start(pipeline, input, config)
    } catch (error) {
      if (error instanceof RunNotStarted) {
        throw new CallError(error.message, config.workDir === null ? 409 : 502)
      }
      throw error
    }
  },

  async stopRun(raw, context): Promise<null> {
    const { executionId } = callParams.stopRun.parse(raw)
    try {
      context.runs.stop(executionId)
    } catch (error) {
      if (error instanceof NotStartedHere) throw new CallError(error.message, 404)
      throw error
    }
    return null
  },

  async previewDraft(raw, context): Promise<CliResult> {
    const { draft } = callParams.previewDraft.parse(raw)
    return previewDraft(draft, context)
  },

  async saveDefinition(raw, context): Promise<null> {
    const { path, previous, text } = callParams.saveDefinition.parse(raw)
    // Only a definition file or a skill's SKILL.md, and only where definitions
    // live: not the records of runs.
    if (!path.endsWith('.synapse') && basename(path) !== 'SKILL.md') {
      throw new CallError('only a definition or a SKILL.md can be saved', 400)
    }
    const config = await loadConfig(context.configFile, context.environment)
    let real: string
    try {
      real = await resolveInside(path, listDefinitionDirs(config, context.environment))
    } catch (error) {
      if (error instanceof OutsideRoots) throw new CallError(error.message, 403)
      throw error
    }
    if ((await readFile(real, 'utf8')) !== previous) {
      throw new CallError('the file has changed since it was read', 409)
    }
    await writeFile(real, text)
    return null
  },

  async generateDefinition(raw, context): Promise<{ text: string }> {
    const request = callParams.generateDefinition.parse(raw)
    const { defaultHarness, defaultModels, env } = await loadConfig(
      context.configFile,
      context.environment,
    )
    const harness = request.harness ?? defaultHarness ?? 'Claude'
    const model = request.model ?? defaultModels[harness]
    try {
      const text = await generateText(request, {
        harness,
        ...(model === undefined ? {} : { model }),
        env,
        pathVariable: context.environment.env.PATH ?? '',
        agent: context.agent,
      })
      return { text }
    } catch (error) {
      if (error instanceof SkillNotFound) throw new CallError(error.message, 409)
      if (error instanceof GenerationFailed) throw new CallError(error.message, 502)
      throw error
    }
  },

  async createNote(raw, context): Promise<{ path: string }> {
    const request = callParams.createNote.parse(raw)
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
    const projects = await listProjects(context.environment)
    const chosen =
      request.project === undefined
        ? undefined
        : projects.find((project) => project.name === request.project)
    if (request.project !== undefined && chosen === undefined) {
      throw new CallError(`${request.project} is not a project in synapse-projects.conf`, 409)
    }
    const list = async (): Promise<string[]> => {
      const result = await context.runCli({ binary: 'synapse', args: ['vault-list'], config })
      if (result.code !== 0) {
        throw new CallError(result.stderr.trim() || 'the vault could not be listed', 502)
      }
      return pathsOf(result.stdout)
    }
    const before = new Set(await list())
    try {
      const run = await session(notePrompt(request.kind, request.prompt, harness, projects, chosen))
      const path = createdPath(run.stdout, before, await list())
      if (path !== null) return { path }
      const why = reasonOf(run.stdout, run.stderr)
      throw new NoteFailed(`No note was written. ${why}`.trim())
    } catch (error) {
      if (error instanceof NoteFailed) throw new CallError(error.message, error.status)
      throw error
    }
  },

  async editNote(raw, context): Promise<NoteEdit> {
    const request = callParams.editNote.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    const harness = request.harness ?? config.defaultHarness ?? 'Claude'
    const session = await noteSessionOf(
      context,
      config,
      harness,
      request.model ?? config.defaultModels[harness],
    )
    try {
      return await editNote(
        { run: context.runCli, config, harness, session },
        request.path,
        request.prompt,
      )
    } catch (error) {
      if (error instanceof EditRefused) throw new CallError(error.message, error.status)
      throw error
    }
  },

  async restoreNote(raw, context): Promise<null> {
    const { path, before, after } = callParams.restoreNote.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    try {
      await restoreNote(context.runCli, config, path, before, after)
      return null
    } catch (error) {
      if (error instanceof EditRefused) throw new CallError(error.message, error.status)
      throw error
    }
  },

  async listProjects(raw, context): Promise<ProjectList> {
    callParams.listProjects.parse(raw)
    return {
      projects: await listProjects(context.environment),
      file: await projectsFile(context.environment),
    }
  },

  async addProject(raw, context): Promise<ProjectList> {
    const { name, prefix } = callParams.addProject.parse(raw)
    try {
      const projects = await addProject(context.environment, name, prefix)
      return { projects, file: await projectsFile(context.environment) }
    } catch (error) {
      if (error instanceof ProjectRefused) throw new CallError(error.message, error.status)
      throw error
    }
  },

  async listConventions(raw, context): Promise<ConventionList> {
    callParams.listConventions.parse(raw)
    return listConventions(context.environment)
  },

  async addConvention(raw, context): Promise<ConventionList> {
    const { id, entry } = callParams.addConvention.parse(raw)
    try {
      return await addConvention(context.environment, id, entry)
    } catch (error) {
      if (error instanceof ConventionRefused) throw new CallError(error.message, error.status)
      throw error
    }
  },

  async removeConvention(raw, context): Promise<ConventionList> {
    const { id, entry } = callParams.removeConvention.parse(raw)
    try {
      return await removeConvention(context.environment, id, entry)
    } catch (error) {
      if (error instanceof ConventionRefused) throw new CallError(error.message, error.status)
      throw error
    }
  },

  async writeDefinition(raw, context): Promise<{ path: string }> {
    const item = callParams.writeDefinition.parse(raw)
    const defaultDir = pipelineConfigDir(context.environment)
    const path =
      item.kind === 'definition'
        ? join(defaultDir, `${item.name}.synapse`)
        : join(defaultDir, 'skills', item.name, 'SKILL.md')
    await mkdir(join(path, '..'), { recursive: true })
    try {
      // `wx` fails when the file is there: a definition is never replaced.
      await writeFile(path, item.text, { flag: 'wx' })
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'EEXIST') {
        throw new CallError(`${item.name} already exists`, 409)
      }
      throw error
    }
    return { path }
  },

  async inspectVault(raw, context): Promise<VaultInfo> {
    const typed = callParams.inspectVault.parse(raw).path
    const path = expandHome(typed, context.environment.home)
    if (!isAbsolute(path)) throw new CallError('the path must be absolute', 400)
    return { ...(await inspectVault(path)), path }
  },

  async listModels(raw, context): Promise<ModelCatalog> {
    const { harness } = callParams.listModels.parse(raw)
    return modelsOf(context).list(harness)
  },

  async refreshModels(raw, context): Promise<ModelCatalog> {
    const { harness } = callParams.refreshModels.parse(raw)
    return modelsOf(context).refresh(harness)
  },

  async listSessions(raw, context): Promise<PastSessions> {
    callParams.listSessions.parse(raw)
    return listSessions(histories(context.environment))
  },

  async listWorkspaces(raw, context): Promise<Workspaces> {
    callParams.listWorkspaces.parse(raw)
    return listWorkspaces(histories(context.environment))
  },

  async getDiagnosis(raw, context): Promise<Diagnosis> {
    callParams.getDiagnosis.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    return diagnose(config, { runCli: context.runCli, env: context.environment.env })
  },

  async seedVault(raw, context): Promise<VaultInfo> {
    const typed = callParams.seedVault.parse(raw).path
    const path = expandHome(typed, context.environment.home)
    if (!isAbsolute(path)) throw new CallError('the path must be absolute', 400)
    const config = await loadConfig(context.configFile, context.environment)
    const root = await findContentRoot(cliEnvironment(context.environment.env, config))
    try {
      await seedVault(path, root === null ? null : join(root, 'Index.md.template'))
    } catch (error) {
      if (error instanceof VaultRefused) throw new CallError(error.message, error.status)
      throw error
    }
    return { ...(await inspectVault(path)), path }
  },

  async checkGraphRepo(raw, context): Promise<GraphRepoCheck> {
    const typed = callParams.checkGraphRepo.parse(raw).path
    const config = await loadConfig(context.configFile, context.environment)
    return checkGraphRepo(context.runCli, config, expandHome(typed, context.environment.home))
  },

  async findGraphRepos(raw, context): Promise<GraphRepoMatches> {
    const { namespace } = callParams.findGraphRepos.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    return { paths: await findGraphRepos(context.runCli, config, namespace) }
  },

  async graphHealth(raw, context): Promise<GraphHealth> {
    const { namespace } = callParams.graphHealth.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    const repo = config.graphRepos[namespace]
    if (repo === undefined) {
      throw new CallError('no repository is saved for this graph', 409)
    }
    if (!(await stat(repo).catch(() => null))?.isDirectory()) {
      throw new CallError(`${repo} is not a folder`, 409)
    }
    return graphHealth(context.runCli, config, namespace, repo)
  },

  async planGraphDrop(raw, context): Promise<GraphPlan> {
    const { namespace } = callParams.planGraphDrop.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    return refusing(() => planGraphDrop(context.runCli, config, namespace))
  },

  async dropGraph(raw, context): Promise<{ output: string }> {
    const { namespace } = callParams.dropGraph.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    return refusing(() => dropGraph(context.runCli, config, namespace))
  },

  async planGraphClean(raw, context): Promise<GraphPlan> {
    const { namespace } = callParams.planGraphClean.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    return refusing(() => planGraphClean(context.runCli, config, namespace))
  },

  async cleanGraphs(raw, context): Promise<{ output: string }> {
    const { namespace } = callParams.cleanGraphs.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    return refusing(() => cleanGraphs(context.runCli, config, namespace))
  },

  async getIntegrations(raw, context): Promise<Integrations> {
    callParams.getIntegrations.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    return inspectIntegrations({
      env: cliEnvironment(context.environment.env, config),
      home: context.environment.home,
      versionOf: versionOfProgram,
    })
  },

  async getConfig(raw, context): Promise<AppConfig> {
    callParams.getConfig.parse(raw)
    return loadConfig(context.configFile, context.environment)
  },

  async setConfig(raw, context): Promise<AppConfig> {
    const { patch } = callParams.setConfig.parse(raw)
    const merged = expandConfigPaths(
      appConfigSchema.parse({
        ...(await loadStoredConfig(context.configFile)),
        ...patch,
      }),
      context.environment.home,
    )
    await saveConfig(context.configFile, merged)
    return loadConfig(context.configFile, context.environment)
  },
}

export async function handleCall(
  name: string,
  params: unknown,
  context: Context,
): Promise<unknown> {
  if (!isCallName(name)) throw new CallError(`unknown method ${name}`, 404)
  try {
    return await handlers[name](params, context)
  } catch (error) {
    if (error instanceof ZodError) throw new CallError(`invalid parameters: ${error.message}`, 400)
    throw error
  }
}
