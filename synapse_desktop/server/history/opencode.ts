import { stat } from 'node:fs/promises'
import { join } from 'node:path'
import type { Workspace } from '../../shared/transport.ts'
import type { Environment } from '../roots.ts'
import type { HarnessHistory } from './history.ts'
import { MAX_WORKSPACES } from './order.ts'

// The table the sessions are in: `session_v2` in the versions that have it, which holds every
// session of the older `session` table as well, else `session`.
function sessionTable(db: { prepare(sql: string): { get(...params: string[]): unknown } }): string {
  const has = db.prepare("select 1 as found from sqlite_master where type = 'table' and name = ?")
  return has.get('session_v2') === undefined ? 'session' : 'session_v2'
}

// The folders OpenCode has sessions in, the most recently used first. OpenCode asks for no
// permission to work in a folder, so its sessions are what says where it has been.
export async function opencodeWorkspaces(database: string): Promise<Workspace[]> {
  if ((await stat(database).catch(() => null)) === null) return []
  // Loaded when needed: Node says the module is experimental when it is first used.
  const { DatabaseSync } = await import('node:sqlite')
  const db = new DatabaseSync(database, { readOnly: true })
  try {
    const rows = db
      .prepare(
        `select directory, max(time_updated) as used from ${sessionTable(db)}
         where parent_id is null group by directory order by used desc limit ?`,
      )
      .all(MAX_WORKSPACES * 2)
    return rows.flatMap((row) =>
      typeof row.directory === 'string' && row.directory !== ''
        ? [
            {
              path: row.directory,
              lastUsed: typeof row.used === 'number' ? new Date(row.used).toISOString() : null,
            },
          ]
        : [],
    )
  } finally {
    db.close()
  }
}

export function opencodeHistory({ env, home }: Environment): HarnessHistory {
  const database = join(
    env.XDG_DATA_HOME || join(home, '.local', 'share'),
    'opencode',
    'opencode.db',
  )
  return {
    harness: 'Opencode',
    workspaces: () => opencodeWorkspaces(database),
  }
}
