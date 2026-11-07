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
  Integrations,
  RunAnswer,
  VaultInfo,
} from '../shared/transport.ts'
import { cliEnvironment, refuseCli, type CliRunner } from './cli.ts'
import { findGraphRepos } from './graph-find.ts'
import { checkGraphRepo, graphHealth } from './graph-health.ts'
import {
  cleanGraphs,
  dropGraph,
  GraphActionRefused,
  planGraphClean,
  planGraphDrop,
} from './graph-manage.ts'
import { findContentRoot } from './inject.ts'
import { findPipelineRoot, inspectIntegrations, versionOfProgram } from './integrations.ts'
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
import { previewDraft } from './preview.ts'
import { inspectVault } from './vault.ts'
import { askRun, NotListening, socketPath } from './run-socket.ts'
import { NotStartedHere, RunNotStarted, type RunStarter } from './runs.ts'

const MAX_FILE_BYTES = 4 * 1024 * 1024

export interface Context {
  environment: Environment
  configFile: string
  runCli: CliRunner
  runs: RunStarter
  agent: AgentRunner
}

// An error with the HTTP status the caller should see.
export class CallError extends Error {
  status: number

  constructor(message: string, status: number) {
    super(message)
    this.status = status
  }
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
    const { defaultHarness, env } = await loadConfig(context.configFile, context.environment)
    try {
      const text = await generateText(request, {
        harness: request.harness ?? defaultHarness ?? 'Claude',
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

  async inspectVault(raw): Promise<VaultInfo> {
    const { path } = callParams.inspectVault.parse(raw)
    if (!isAbsolute(path)) throw new CallError('the path must be absolute', 400)
    return inspectVault(path)
  },

  async checkGraphRepo(raw, context): Promise<GraphRepoCheck> {
    const { path } = callParams.checkGraphRepo.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    return checkGraphRepo(context.runCli, config, path)
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

  async configureHarness(raw, context): Promise<{ output: string }> {
    const { harness } = callParams.configureHarness.parse(raw)
    const config = await loadConfig(context.configFile, context.environment)
    const env = cliEnvironment(context.environment.env, config)
    const contentRoot = await findContentRoot(env)
    const pipelineRoot = await findPipelineRoot(env)
    if (contentRoot === null)
      throw new CallError('the skills and hooks of Synapse were not found', 409)
    if (pipelineRoot === null) {
      throw new CallError('the skills of synapse-pipeline were not found', 409)
    }
    const name = harness.toLowerCase()
    const output: string[] = []
    for (const [binary, root] of [
      ['synapse', contentRoot],
      ['synapse-pipeline', pipelineRoot],
    ] as const) {
      const result = await context.runCli({
        binary,
        args: ['configure', name],
        config,
        env: { SYNAPSE_CONTENT_ROOT: root },
      })
      if (result.code !== 0) {
        throw new CallError(
          `${binary} configure ${name} failed: ${(result.stderr || result.stdout).trim()}`,
          502,
        )
      }
      output.push(result.stdout.trim())
    }
    return { output: output.filter(Boolean).join('\n\n') }
  },

  async getConfig(raw, context): Promise<AppConfig> {
    callParams.getConfig.parse(raw)
    return loadConfig(context.configFile, context.environment)
  },

  async setConfig(raw, context): Promise<AppConfig> {
    const { patch } = callParams.setConfig.parse(raw)
    const merged = appConfigSchema.parse({
      ...(await loadStoredConfig(context.configFile)),
      ...patch,
    })
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
