// The app's own settings, kept in one JSON file.

import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { defaultConfig, storedConfigSchema } from '../shared/calls.ts'
import type { AppConfig } from '../shared/transport.ts'
import type { Environment } from './roots.ts'

// $XDG_CONFIG_HOME/synapse-desktop/config.json, or ~/.config/synapse-desktop/config.json.
export function configFile({ env, home }: Environment): string {
  const base = env.XDG_CONFIG_HOME ? env.XDG_CONFIG_HOME : join(home, '.config')
  return join(base, 'synapse-desktop', 'config.json')
}

// What the file says. A missing file is the default configuration; a file that
// does not parse is an error.
export async function loadStoredConfig(file: string): Promise<AppConfig> {
  let text: string
  try {
    text = await readFile(file, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return { ...defaultConfig }
    throw error
  }
  return storedConfigSchema.parse(JSON.parse(text))
}

// The configuration in force. The work directory is SYNAPSE_WORK_DIR when the
// app sets it for its programs or the server was started with it, as for
// `synapse-pipeline` itself, and otherwise the one saved.
export async function loadConfig(file: string, env: NodeJS.ProcessEnv): Promise<AppConfig> {
  const stored = await loadStoredConfig(file)
  const fromEnvironment = stored.env.SYNAPSE_WORK_DIR || env.SYNAPSE_WORK_DIR
  return fromEnvironment ? { ...stored, workDir: fromEnvironment } : stored
}

// Written beside the file and renamed over it, so a reader never sees half of it.
export async function saveConfig(file: string, config: AppConfig): Promise<void> {
  await mkdir(dirname(file), { recursive: true })
  const temporary = `${file}.tmp`
  await writeFile(temporary, JSON.stringify(config, null, 2) + '\n')
  await rename(temporary, file)
}
