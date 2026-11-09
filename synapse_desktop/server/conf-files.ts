// Where one of Synapse's `synapse-*.conf` files is: the first of
// `$XDG_CONFIG_HOME/synapse/` (or `~/.config/synapse/`) and `~/.claude/` that has it. A
// file that is in neither is made in the first of them, or in `~/.claude/` when
// `~/.config` is not there, as the programs and skills that write them decide.

import { stat } from 'node:fs/promises'
import { join } from 'node:path'
import type { Environment } from './roots.ts'

async function exists(path: string): Promise<boolean> {
  return (await stat(path).catch(() => null))?.isFile() ?? false
}

export async function confFile({ env, home }: Environment, name: string): Promise<string> {
  const base = env.XDG_CONFIG_HOME ? env.XDG_CONFIG_HOME : join(home, '.config')
  const candidates = [join(base, 'synapse', name), join(home, '.claude', name)]
  for (const candidate of candidates) {
    if (await exists(candidate)) return candidate
  }
  const baseIsThere = (await stat(base).catch(() => null))?.isDirectory() ?? false
  return env.XDG_CONFIG_HOME || baseIsThere ? candidates[0]! : candidates[1]!
}
