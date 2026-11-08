// What a folder that may be a vault looks like, for the page that switches the
// vault.

import { constants } from 'node:fs'
import { copyFile, mkdir, readdir, stat } from 'node:fs/promises'
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

export class VaultRefused extends Error {
  status: number

  constructor(message: string, status = 409) {
    super(message)
    this.status = status
  }
}

// Makes a folder a vault: the folder, and an `Index.md` made from the template the package
// ships when there is none. What is in the folder is left as it is, the `Index.md` of a
// vault that has one included.
export async function seedVault(path: string, template: string | null): Promise<void> {
  const info = await stat(path).catch(() => null)
  if (info !== null && !info.isDirectory()) throw new VaultRefused(`${path} is not a folder`)
  const index = join(path, 'Index.md')
  const seeded = await isThere(index, 'file')
  // Nothing is made when what it is made from is not there.
  if (!seeded && (template === null || !(await isThere(template, 'file')))) {
    throw new VaultRefused('The Index.md template of Synapse was not found.')
  }
  await mkdir(path, { recursive: true })
  if (seeded) return
  // `COPYFILE_EXCL`: a file that appeared meanwhile is not written over.
  await copyFile(template as string, index, constants.COPYFILE_EXCL).catch(
    (error: NodeJS.ErrnoException) => {
      if (error.code !== 'EEXIST') throw error
    },
  )
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
