import { readdir, readFile, stat } from 'node:fs/promises'
import { join } from 'node:path'
import type { PastSession, Workspace } from '../../shared/transport.ts'
import type { Environment } from '../roots.ts'
import type { HarnessHistory } from './history.ts'
import { CANDIDATES, head, jsonLine, newestFirst, titleOf } from './order.ts'

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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

// What a rollout file says of its session in its first lines: the id and the folder, and the
// first prompt, which is the first message of the user that is not context the harness added
// (those are in tags).
export function codexSessionHead(text: string): {
  id: string | null
  cwd: string | null
  title: string | null
} {
  let id: string | null = null
  let cwd: string | null = null
  let title: string | null = null
  for (const line of text.split('\n')) {
    const record = jsonLine(line, 500_000)
    const payload = record?.payload
    if (record === null || !isRecord(payload)) continue
    if (record.type === 'session_meta') {
      if (typeof payload.id === 'string') id = payload.id
      if (typeof payload.cwd === 'string') cwd = payload.cwd
    } else if (
      title === null &&
      record.type === 'response_item' &&
      payload.type === 'message' &&
      payload.role === 'user' &&
      Array.isArray(payload.content)
    ) {
      for (const part of payload.content) {
        if (
          isRecord(part) &&
          typeof part.text === 'string' &&
          !part.text.trimStart().startsWith('<')
        ) {
          title = titleOf(part.text)
          break
        }
      }
    }
    if (id !== null && cwd !== null && title !== null) break
  }
  return { id, cwd, title }
}

// The newest rollout files, found by their folders of year, month and day and their names,
// which start with the time.
async function newestRollouts(root: string, limit: number): Promise<string[]> {
  const newestFirstNames = async (dir: string) =>
    (await readdir(dir).catch(() => [])).sort().reverse()
  const found: string[] = []
  for (const year of await newestFirstNames(root)) {
    for (const month of await newestFirstNames(join(root, year))) {
      for (const day of await newestFirstNames(join(root, year, month))) {
        for (const name of await newestFirstNames(join(root, year, month, day))) {
          if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue
          found.push(join(root, year, month, day, name))
          if (found.length >= limit) return found
        }
      }
    }
  }
  return found
}

const HEAD_BYTES = 512 * 1024

export function codexHistory({ env, home }: Environment): HarnessHistory {
  const codexHome = env.CODEX_HOME || join(home, '.codex')
  const file = join(codexHome, 'config.toml')
  return {
    harness: 'Codex',
    async workspaces() {
      return codexWorkspaces(await readFile(file, 'utf8').catch(() => ''))
    },
    async sessions() {
      const files = await newestRollouts(join(codexHome, 'sessions'), CANDIDATES)
      const read = await Promise.all(
        files.map(async (path): Promise<PastSession | null> => {
          const { id, cwd, title } = codexSessionHead(await head(path, HEAD_BYTES).catch(() => ''))
          const seen = await stat(path).catch(() => null)
          return id === null || cwd === null
            ? null
            : { id, path: cwd, title, lastUsed: seen === null ? null : seen.mtime.toISOString() }
        }),
      )
      return newestFirst(read.filter((s): s is PastSession => s !== null))
    },
  }
}
