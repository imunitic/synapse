// What a folder that may be a vault looks like, for the page that switches the
// vault.

import { readdir, stat } from 'node:fs/promises'
import { join } from 'node:path'
import type { VaultInfo } from '../shared/transport.ts'

// A walk stops after this many entries, so a folder that is not a vault, such as
// a home directory, does not keep the app busy.
const MAX_ENTRIES = 20_000

async function isThere(path: string, want: 'file' | 'directory'): Promise<boolean> {
  const info = await stat(path).catch(() => null)
  return info !== null && (want === 'file' ? info.isFile() : info.isDirectory())
}

// Notes are Markdown files. Folders that start with a dot, such as `.git` and
// `.obsidian`, hold no notes.
async function countNotes(root: string): Promise<{ notes: number; capped: boolean }> {
  let notes = 0
  let seen = 0
  const pending = [root]
  while (pending.length > 0) {
    const dir = pending.pop() as string
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => [])
    for (const entry of entries) {
      if (++seen > MAX_ENTRIES) return { notes, capped: true }
      if (entry.isDirectory()) {
        if (!entry.name.startsWith('.')) pending.push(join(dir, entry.name))
      } else if (entry.isFile() && entry.name.endsWith('.md')) {
        notes++
      }
    }
  }
  return { notes, capped: false }
}

export async function inspectVault(path: string): Promise<Omit<VaultInfo, 'path'>> {
  if (!(await isThere(path, 'directory'))) {
    return { exists: false, hasIndex: false, isGit: false, notes: 0, capped: false }
  }
  const [hasIndex, isGit, counted] = await Promise.all([
    isThere(join(path, 'Index.md'), 'file'),
    isThere(join(path, '.git'), 'directory'),
    countNotes(path),
  ])
  return { exists: true, hasIndex, isGit, ...counted }
}
