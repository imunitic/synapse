// The directories the file primitives may reach: the work directory's records
// and the places definitions are looked for.

import { realpath } from 'node:fs/promises'
import { delimiter, isAbsolute, join, sep } from 'node:path'
import type { AppConfig } from '../shared/transport.ts'

export interface Environment {
  env: Record<string, string | undefined>
  home: string
}

// $XDG_CONFIG_HOME/synapse-pipeline, or ~/.config/synapse-pipeline when unset.
export function pipelineConfigDir({ env, home }: Environment): string {
  const base = env.XDG_CONFIG_HOME ? env.XDG_CONFIG_HOME : join(home, '.config')
  return join(base, 'synapse-pipeline')
}

// The directories of .synapse files: SYNAPSE_PIPELINE_PATH, the default
// directory, and those the user added in the settings.
export function definitionDirs(config: AppConfig, environment: Environment): string[] {
  const fromEnv = (environment.env.SYNAPSE_PIPELINE_PATH ?? '').split(delimiter).filter(Boolean)
  return [...fromEnv, pipelineConfigDir(environment), ...config.definitionPaths]
}

export function allowedRoots(config: AppConfig, environment: Environment): string[] {
  const roots = definitionDirs(config, environment)
  if (config.workDir !== null) roots.push(join(config.workDir, 'pipelines'))
  return roots
}

export class OutsideRoots extends Error {}

// The real path of target when it lies inside one of the roots, after
// following symbolic links, so a link or a `..` cannot lead out.
export async function resolveInside(target: string, roots: readonly string[]): Promise<string> {
  if (!isAbsolute(target)) throw new OutsideRoots('path must be absolute')
  let real: string
  try {
    real = await realpath(target)
  } catch {
    throw new OutsideRoots('not found')
  }
  for (const root of roots) {
    let realRoot: string
    try {
      realRoot = await realpath(root)
    } catch {
      continue
    }
    if (real === realRoot || real.startsWith(realRoot + sep)) return real
  }
  throw new OutsideRoots('path is outside the allowed directories')
}
