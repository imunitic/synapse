import { readdir, readFile, stat } from 'node:fs/promises'
import { join } from 'node:path'
import type { PastSession, Workspace } from '../../shared/transport.ts'
import type { Environment } from '../roots.ts'
import type { HarnessHistory } from './history.ts'
import { CANDIDATES, head, jsonLine, newestFirst, titleOf } from './order.ts'

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

// The folders of `.claude.json` that Claude Code has been allowed to work in. Only the folder,
// whether it was allowed and when it was last used are read: the file holds more.
export function claudeWorkspaces(text: string): Workspace[] {
  let document: unknown
  try {
    document = JSON.parse(text)
  } catch {
    return []
  }
  const projects = isRecord(document) ? document.projects : null
  if (!isRecord(projects)) return []
  const found: Workspace[] = []
  for (const [path, entry] of Object.entries(projects)) {
    if (!isRecord(entry) || entry.hasTrustDialogAccepted !== true) continue
    const used = entry.lastSessionModified
    found.push({
      path,
      lastUsed: typeof used === 'number' ? new Date(used).toISOString() : null,
    })
  }
  return newestFirst(found)
}

// Where a session file says its folder is, and what it is called, from the start of the file.
// A line that holds a whole request or a file is long and is not read.
export function claudeSessionHead(text: string): { cwd: string | null; title: string | null } {
  let cwd: string | null = null
  let named: string | null = null
  let prompt: string | null = null
  for (const line of text.split('\n')) {
    const record = jsonLine(line)
    if (record === null) continue
    if (cwd === null && typeof record.cwd === 'string') cwd = record.cwd
    if (record.type === 'ai-title' && typeof record.aiTitle === 'string') named = record.aiTitle
    if (record.type === 'last-prompt' && typeof record.lastPrompt === 'string') {
      prompt = record.lastPrompt
    }
  }
  return { cwd, title: titleOf(named ?? prompt ?? '') }
}

// How much of the start of a session file is read: the title is in the first few hundred
// kilobytes of a file that can be tens of megabytes.
const HEAD_BYTES = 1024 * 1024

// The folder of the sessions of a working folder: its path with every character that is not
// a letter or a digit made a hyphen.
export function projectFolderName(path: string): string {
  return path.replace(/[^a-zA-Z0-9]/g, '-')
}

export function claudeHistory({ env, home }: Environment): HarnessHistory {
  const file = join(env.CLAUDE_CONFIG_DIR || home, '.claude.json')
  const projects = join(env.CLAUDE_CONFIG_DIR || join(home, '.claude'), 'projects')
  return {
    harness: 'Claude',
    async workspaces() {
      const found = claudeWorkspaces(await readFile(file, 'utf8').catch(() => ''))
      // A folder the file gives no time for was last used when its sessions folder last changed.
      const timed = await Promise.all(
        found.map(async (workspace) => {
          if (workspace.lastUsed !== null) return workspace
          const seen = await stat(join(projects, projectFolderName(workspace.path))).catch(
            () => null,
          )
          return { ...workspace, lastUsed: seen === null ? null : seen.mtime.toISOString() }
        }),
      )
      return newestFirst(timed)
    },
    async sessions() {
      const files: { id: string; file: string; used: Date }[] = []
      for (const folder of await readdir(projects).catch(() => [])) {
        for (const name of await readdir(join(projects, folder)).catch(() => [])) {
          if (!name.endsWith('.jsonl')) continue
          const file = join(projects, folder, name)
          const seen = await stat(file).catch(() => null)
          if (seen?.isFile())
            files.push({ id: name.slice(0, -'.jsonl'.length), file, used: seen.mtime })
        }
      }
      files.sort((a, b) => b.used.getTime() - a.used.getTime())
      const read = await Promise.all(
        files.slice(0, CANDIDATES).map(async ({ id, file, used }): Promise<PastSession | null> => {
          const { cwd, title } = claudeSessionHead(await head(file, HEAD_BYTES).catch(() => ''))
          return cwd === null ? null : { id, path: cwd, title, lastUsed: used.toISOString() }
        }),
      )
      return newestFirst(read.filter((s): s is PastSession => s !== null))
    },
  }
}
