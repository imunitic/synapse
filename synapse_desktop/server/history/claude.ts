import { readFile, stat } from 'node:fs/promises'
import { join } from 'node:path'
import type { Workspace } from '../../shared/transport.ts'
import type { Environment } from '../roots.ts'
import type { HarnessHistory } from './history.ts'
import { newestFirst } from './order.ts'

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
  }
}
