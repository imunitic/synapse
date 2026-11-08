import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { Workspace } from '../../shared/transport.ts'
import type { Environment } from '../roots.ts'
import type { HarnessHistory } from './history.ts'

const TABLE = /^\[projects\.("(?:[^"\\]|\\.)*"|'[^']*')\]\s*(#.*)?$/
const TRUSTED = /^trust_level\s*=\s*["']trusted["']\s*(#.*)?$/

function keyOf(quoted: string): string | null {
  if (quoted.startsWith("'")) return quoted.slice(1, -1)
  try {
    const parsed: unknown = JSON.parse(quoted)
    return typeof parsed === 'string' ? parsed : null
  } catch {
    return null
  }
}

// The folders of `config.toml` that Codex trusts: a `[projects."<folder>"]` table with
// `trust_level = "trusted"`. The file keeps no time of use, so they come the newest
// approved first, which is the end of the file, where Codex appends.
export function codexWorkspaces(text: string): Workspace[] {
  const found: Workspace[] = []
  let current: string | null = null
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line.startsWith('[')) {
      const match = TABLE.exec(line)
      current = match?.[1] === undefined ? null : keyOf(match[1])
    } else if (current !== null && TRUSTED.test(line)) {
      found.push({ path: current, lastUsed: null })
      current = null
    }
  }
  return found.reverse()
}

export function codexHistory({ env, home }: Environment): HarnessHistory {
  const file = join(env.CODEX_HOME || join(home, '.codex'), 'config.toml')
  return {
    harness: 'Codex',
    async workspaces() {
      return codexWorkspaces(await readFile(file, 'utf8').catch(() => ''))
    },
  }
}
