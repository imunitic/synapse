// The files a folder's changes are made of, for the list the Changes sidebar shows: those the
// patch holds, and the new files, which the host lists by path and number of lines and whose content
// is asked for when a row is opened.

import type { AddedFile } from '../../shared/changes.ts'
import { parseUnifiedDiff, type FileDiff, type FileStatus } from './unified-diff.ts'

export interface ChangedFile {
  path: string
  // Where a renamed file was.
  oldPath: string | null
  status: FileStatus
  // Null for a binary file, which has no lines to count.
  added: number | null
  removed: number | null
  binary: boolean
  // Whether its content is not in the patch, and is read when its row is opened.
  deferred: boolean
}

export interface ChangeSet {
  files: ChangedFile[]
  // The diff of each file the patch holds, by its path.
  diffs: ReadonlyMap<string, FileDiff>
}

export function changeSet(patch: string, added: readonly AddedFile[]): ChangeSet {
  const diffs = new Map<string, FileDiff>()
  const files: ChangedFile[] = []
  for (const diff of parseUnifiedDiff(patch)) {
    diffs.set(diff.path, diff)
    files.push({
      path: diff.path,
      oldPath: diff.oldPath,
      status: diff.status,
      added: diff.binary ? null : diff.added,
      removed: diff.binary ? null : diff.removed,
      binary: diff.binary,
      deferred: false,
    })
  }
  for (const file of added) {
    files.push({
      path: file.path,
      oldPath: null,
      status: 'added',
      added: file.lines,
      removed: file.lines === null ? null : 0,
      binary: file.lines === null,
      deferred: true,
    })
  }
  files.sort((a, b) => a.path.localeCompare(b.path))
  return { files, diffs }
}

// The folder a path is in, empty for one at the top.
export function folderOf(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash === -1 ? '' : path.slice(0, slash)
}

export interface FolderGroup {
  folder: string
  files: ChangedFile[]
}

// The files under the folder each is in, the files at the top first.
export function groupByFolder(files: readonly ChangedFile[]): FolderGroup[] {
  const groups = new Map<string, ChangedFile[]>()
  for (const file of files) {
    const folder = folderOf(file.path)
    groups.set(folder, [...(groups.get(folder) ?? []), file])
  }
  return [...groups]
    .map(([folder, inside]) => ({ folder, files: inside }))
    .sort((a, b) => a.folder.localeCompare(b.folder))
}

// How many files a set of changes has, and its lines added and removed; a binary file is a file
// with no lines.
export function groupTotals(set: ChangeSet): { files: number; added: number; removed: number } {
  return {
    files: set.files.length,
    added: set.files.reduce((sum, f) => sum + (f.added ?? 0), 0),
    removed: set.files.reduce((sum, f) => sum + (f.removed ?? 0), 0),
  }
}

// The name of a path without its folder.
export function baseName(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1)
}

// Whether a file an activity names, by its whole path, is the file of a change, which is named
// from the root of the repository: the path ends with it, at a folder.
export function pathMatches(absolute: string, relative: string): boolean {
  const whole = absolute.replaceAll('\\', '/')
  return whole === relative || whole.endsWith(`/${relative}`)
}

// What a session's changes are against: the folder as it was when the session started, or the last
// commit, which makes everything not committed a change.
export type ChangesBase = 'start' | 'commit'

// The base for a session when the person has not chosen one. A session that continues an earlier
// one begins after that one's work is in the folder, so it is compared with the last commit.
export function defaultBase(session: { resume?: string }): ChangesBase {
  return session.resume === undefined ? 'start' : 'commit'
}

// A branch by its name, a commit when HEAD was detached by the first seven digits of its id.
function positionName(head: string): string {
  return /^[0-9a-f]{40}([0-9a-f]{24})?$/.test(head) ? head.slice(0, 7) : head
}

// What a session's changes are compared with: once it has been on more than one branch, the branch
// its snapshot is of, and whether that was taken when the session switched to it.
export function sinceLabel(position: { head: string; switched: boolean } | null): string {
  if (position === null) return 'Since the session started'
  const name = positionName(position.head)
  return position.switched ? `Since switching to ${name}` : `Since the session started on ${name}`
}
