// The API calls: each one validates its own parameters and reaches only what
// the roots and the CLI allowlist let it.

import { readdir, readFile, stat } from 'node:fs/promises'
import { join } from 'node:path'
import { ZodError } from 'zod'
import { appConfigSchema, callParams, isCallName, type CallName } from '../shared/calls.ts'
import type { AppConfig, AppPaths, CliResult, DirEntry, RunAnswer } from '../shared/transport.ts'
import { refuseCli, type CliRunner } from './cli.ts'
import { loadConfig, saveConfig } from './config-store.ts'
import {
  allowedRoots,
  definitionDirs as listDefinitionDirs,
  existingDirs,
  OutsideRoots,
  pipelineConfigDir,
  resolveInside,
  type Environment,
} from './roots.ts'
import { askRun, NotListening, socketPath } from './run-socket.ts'
import { NotStartedHere, RunNotStarted, type RunStarter } from './runs.ts'

const MAX_FILE_BYTES = 4 * 1024 * 1024

export interface Context {
  environment: Environment
  configFile: string
  runCli: CliRunner
  runs: RunStarter
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

async function insideRoots(path: string, context: Context): Promise<string> {
  const config = await loadConfig(context.configFile)
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
    const config = await loadConfig(context.configFile)
    return context.runCli({ binary, args, stdin, config })
  },

  async runRequest(raw, context): Promise<RunAnswer> {
    const { executionId, request } = callParams.runRequest.parse(raw)
    const { workDir } = await loadConfig(context.configFile)
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
    const config = await loadConfig(context.configFile)
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
    const config = await loadConfig(context.configFile)
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

  async getConfig(raw, context): Promise<AppConfig> {
    callParams.getConfig.parse(raw)
    return loadConfig(context.configFile)
  },

  async setConfig(raw, context): Promise<AppConfig> {
    const { patch } = callParams.setConfig.parse(raw)
    const merged = appConfigSchema.parse({ ...(await loadConfig(context.configFile)), ...patch })
    await saveConfig(context.configFile, merged)
    return merged
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
