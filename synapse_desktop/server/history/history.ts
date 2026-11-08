// What a harness remembers of its own use, behind one interface so that the rest of the
// app asks the same question of every harness and does not know where each keeps its answer.

import type {
  Harness,
  PastSession,
  PastSessions,
  Workspace,
  Workspaces,
} from '../../shared/transport.ts'
import { isDirectory } from '../fs-checks.ts'
import type { Environment } from '../roots.ts'
import { claudeHistory } from './claude.ts'
import { codexHistory } from './codex.ts'
import { opencodeHistory } from './opencode.ts'
import { MAX_SESSIONS, MAX_WORKSPACES } from './order.ts'

export interface HarnessHistory {
  readonly harness: Harness
  // The folders the harness already works in, most recently used first. A folder it
  // has been allowed to work in, where it has a notion of that, else one it has sessions in.
  // A file that is missing or cannot be read gives none.
  workspaces(): Promise<Workspace[]>
  // The sessions it has kept, most recently used first, each with the folder it was held in and
  // the first words of what it was about. Not every one: the newest.
  sessions(): Promise<PastSession[]>
}

export function histories(environment: Environment): HarnessHistory[] {
  return [claudeHistory(environment), codexHistory(environment), opencodeHistory(environment)]
}

// A folder that is gone is not one to start in.
async function present(found: readonly Workspace[]): Promise<Workspace[]> {
  const checks = await Promise.all(found.map((w) => isDirectory(w.path)))
  return found.filter((_, i) => checks[i] === true).slice(0, MAX_WORKSPACES)
}

export async function listWorkspaces(all: readonly HarnessHistory[]): Promise<Workspaces> {
  const result: Workspaces = { Claude: [], Codex: [], Opencode: [] }
  await Promise.all(
    all.map(async (history) => {
      result[history.harness] = await present(await history.workspaces().catch(() => []))
    }),
  )
  return result
}

// A session whose folder is gone cannot be resumed where it was held.
async function resumable(found: readonly PastSession[]): Promise<PastSession[]> {
  const checks = await Promise.all(found.map((s) => isDirectory(s.path)))
  return found.filter((_, i) => checks[i] === true).slice(0, MAX_SESSIONS)
}

export async function listSessions(all: readonly HarnessHistory[]): Promise<PastSessions> {
  const result: PastSessions = { Claude: [], Codex: [], Opencode: [] }
  await Promise.all(
    all.map(async (history) => {
      result[history.harness] = await resumable(await history.sessions().catch(() => []))
    }),
  )
  return result
}
