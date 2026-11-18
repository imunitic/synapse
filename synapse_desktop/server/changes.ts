// The changes made in a working tree, from git, without touching the repository. A snapshot is the
// tree object made from a temporary index, so nothing is committed, stashed or staged and the real
// index is left alone; the changes are the difference between two snapshots.

import { execFile } from 'node:child_process'
import { copyFile, mkdtemp, rm, stat, utimes } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { HostError } from '../shared/dispatch.ts'
import {
  MAX_PATCH_BYTES,
  type Commit,
  type CommitLog,
  type FolderChanges,
} from '../shared/changes.ts'

const TIMEOUT_MS = 60_000

interface GitResult {
  code: number
  stdout: string
  stderr: string
}

// A non-zero exit is a result. The variables that point git at another repository are not passed
// on, and the user's configuration of external diff programs and text conversions is not used: the
// diff is git's own.
const REPOSITORY_VARIABLES = ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE']

function git(
  folder: string,
  args: readonly string[],
  env: Record<string, string> = {},
): Promise<GitResult> {
  return new Promise((resolve, reject) => {
    const child = execFile(
      'git',
      ['--no-pager', '-c', 'core.quotepath=off', '--literal-pathspecs', ...args],
      {
        cwd: folder,
        env: {
          ...Object.fromEntries(
            Object.entries(process.env).filter(([name]) => !REPOSITORY_VARIABLES.includes(name)),
          ),
          GIT_OPTIONAL_LOCKS: '0',
          GIT_TERMINAL_PROMPT: '0',
          ...env,
        },
        timeout: TIMEOUT_MS,
        maxBuffer: MAX_PATCH_BYTES + 1024,
      },
      (error, stdout, stderr) => {
        if (error === null) resolve({ code: 0, stdout, stderr })
        else if (typeof error.code === 'number') resolve({ code: error.code, stdout, stderr })
        else if ('code' in error && error.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER') {
          reject(new HostError('too_large', 'the changes are too large to show'))
        } else reject(new HostError('unavailable', `git could not be run: ${error.message}`))
      },
    )
    // Git is given nothing to read, and never waits for it.
    child.stdin?.end()
  })
}

// The temporary index starts as a copy of the real one, so that only what changed is read again. It
// keeps the real index's time: git trusts an entry that has the size and the time of its file only
// when the entry is older than the index, and a copy that looked newer would make it trust an entry
// of a file that was written again, with the same size, in the second the index was.
async function copyIndex(from: string, to: string): Promise<void> {
  try {
    const info = await stat(from)
    await copyFile(from, to)
    await utimes(to, info.atime, info.mtime)
  } catch {
    // There is no index yet: the temporary one starts empty.
  }
}

// The id of the tree the working tree is now, or null when the folder is not in a git
// repository. `add -A` brings the temporary index to the working tree: new files in, deleted files
// out, ignored files left out.
export async function snapshotTree(folder: string): Promise<string | null> {
  const there = await stat(folder).catch(() => null)
  if (there === null || !there.isDirectory()) {
    throw new HostError('not_found', 'the folder is not there')
  }
  const inside = await git(folder, ['rev-parse', '--is-inside-work-tree'])
  if (inside.code !== 0 || inside.stdout.trim() !== 'true') return null
  const gitDir = await git(folder, ['rev-parse', '--absolute-git-dir'])
  if (gitDir.code !== 0) return null
  const scratch = await mkdtemp(join(tmpdir(), 'synapse-changes-'))
  try {
    const index = join(scratch, 'index')
    await copyIndex(join(gitDir.stdout.trim(), 'index'), index)
    const env = { GIT_INDEX_FILE: index }
    const added = await git(folder, ['add', '-A'], env)
    if (added.code !== 0) {
      throw new HostError('unavailable', `git add failed: ${added.stderr.trim()}`)
    }
    const tree = await git(folder, ['write-tree'], env)
    if (tree.code !== 0) {
      throw new HostError('unavailable', `git write-tree failed: ${tree.stderr.trim()}`)
    }
    return tree.stdout.trim()
  } finally {
    await rm(scratch, { recursive: true, force: true })
  }
}

// The files of `git diff --numstat -z`, each as `added<TAB>removed<TAB>path` ending in a NUL.
function addedFiles(numstat: string): { path: string; lines: number | null }[] {
  return numstat
    .split('\0')
    .filter((record) => record !== '')
    .map((record) => {
      const [lines, , ...rest] = record.split('\t')
      return { path: rest.join('\t'), lines: lines === '-' ? null : Number(lines) }
    })
}

// The tree of the last commit, the empty tree when there is none, or null when the folder is not in a
// git repository: what everything that is not committed is a change against.
export async function headTree(folder: string): Promise<string | null> {
  const there = await stat(folder).catch(() => null)
  if (there === null || !there.isDirectory()) {
    throw new HostError('not_found', 'the folder is not there')
  }
  const inside = await git(folder, ['rev-parse', '--is-inside-work-tree'])
  if (inside.code !== 0 || inside.stdout.trim() !== 'true') return null
  const head = await git(folder, ['rev-parse', '--verify', '--quiet', 'HEAD^{tree}'])
  if (head.code === 0 && head.stdout.trim() !== '') return head.stdout.trim()
  // No commit yet: git writes the empty tree, whatever hash the repository uses.
  const empty = await git(folder, ['mktree'])
  return empty.code === 0 ? empty.stdout.trim() : null
}

// Where HEAD is: the name of the branch checked out, also before its first commit; the id of the
// commit when HEAD is detached; null when the folder is not in a git repository or HEAD is neither.
export async function headPosition(folder: string): Promise<string | null> {
  const branch = await git(folder, ['symbolic-ref', '--quiet', '--short', 'HEAD'])
  if (branch.code === 0 && branch.stdout.trim() !== '') return branch.stdout.trim()
  const commit = await git(folder, ['rev-parse', '--verify', '--quiet', 'HEAD'])
  if (commit.code === 0 && commit.stdout.trim() !== '') return commit.stdout.trim()
  return null
}

const DIFF = ['diff', '--no-color', '--no-ext-diff', '--no-textconv', '--find-renames']

// What changed in the folder's working tree since the snapshot `before`. Without a path: the patch
// of the files that already existed, and the new files by path and number of lines. With a path:
// that file's patch, a new file's whole content included.
export async function changesSince(
  folder: string,
  before: string,
  path?: string,
): Promise<FolderChanges> {
  if (path?.includes('\0')) throw new HostError('bad_request', 'the path holds a NUL')
  const after = await snapshotTree(folder)
  if (after === null) return { repository: false, patch: '', added: [], head: null }
  const head = await headPosition(folder)
  if (after === before) return { repository: true, patch: '', added: [], head }
  const known = await git(folder, ['cat-file', '-e', `${before}^{tree}`])
  if (known.code !== 0) {
    throw new HostError('not_found', 'the snapshot is not in this repository any more')
  }
  return { repository: true, ...(await diffTrees(folder, before, after, path)), head }
}

// What changed from the tree `before` to the tree `after`. Without a path: the patch of the files
// that already existed, and the new files by path and number of lines. With a path: that file's
// patch, a new file's whole content included.
async function diffTrees(
  folder: string,
  before: string,
  after: string,
  path?: string,
): Promise<{ patch: string; added: { path: string; lines: number | null }[] }> {
  if (path !== undefined) {
    const one = await git(folder, [...DIFF, before, after, '--', path])
    if (one.code !== 0) throw new HostError('unavailable', `git diff failed: ${one.stderr.trim()}`)
    return { patch: one.stdout, added: [] }
  }
  const [patch, numstat] = await Promise.all([
    git(folder, [...DIFF, '--diff-filter=a', before, after]),
    git(folder, [...DIFF, '--numstat', '-z', '--diff-filter=A', before, after]),
  ])
  if (patch.code !== 0 || numstat.code !== 0) {
    throw new HostError(
      'unavailable',
      `git diff failed: ${(patch.stderr || numstat.stderr).trim()}`,
    )
  }
  return { patch: patch.stdout, added: addedFiles(numstat.stdout) }
}

// A commit named by a page: hexadecimal only, so that git never reads it as an option.
const COMMIT_ID = /^[0-9a-f]{7,64}$/

function checkCommitId(id: string): void {
  if (!COMMIT_ID.test(id)) throw new HostError('bad_request', `'${id}' is not a commit`)
}

// Whether the folder is in a git repository; refused when the folder is not there.
async function inRepository(folder: string): Promise<boolean> {
  const there = await stat(folder).catch(() => null)
  if (there === null || !there.isDirectory()) {
    throw new HostError('not_found', 'the folder is not there')
  }
  const inside = await git(folder, ['rev-parse', '--is-inside-work-tree'])
  return inside.code === 0 && inside.stdout.trim() === 'true'
}

// The fields of a commit in `git log`, after a record separator and separated by unit separators,
// which a one-line subject does not hold; its `--shortstat` line follows them.
const LOG_FORMAT = '--format=%x1e%H%x1f%s%x1f%an%x1f%cI'

// The lines a `--shortstat` line counts: ` 3 files changed, 290 insertions(+), 93 deletions(-)`,
// either count left out when it is none.
function shortstat(text: string): { added: number; removed: number } {
  const count = (word: RegExp) => Number(word.exec(text)?.[1] ?? 0)
  return { added: count(/(\d+) insertions?\(\+\)/), removed: count(/(\d+) deletions?\(-\)/) }
}

// The commits of HEAD, newest first along the first parent, at most `limit`; with `before`, those
// after that one. A merge is one commit of the branch; what it brought in is not listed, and its
// lines are counted against its first parent.
export async function commitLog(
  folder: string,
  limit: number,
  before?: string,
): Promise<CommitLog> {
  if (before !== undefined) checkCommitId(before)
  if (!(await inRepository(folder))) return { repository: false, commits: [], more: false }
  const head = await git(folder, ['rev-parse', '--verify', '--quiet', 'HEAD'])
  if (head.code !== 0) return { repository: true, commits: [], more: false }
  // One more than asked for says whether there are more; `before` itself comes first and is dropped.
  const count = limit + 1 + (before === undefined ? 0 : 1)
  const log = await git(folder, [
    'log',
    '--first-parent',
    '--diff-merges=first-parent',
    '--shortstat',
    '--no-color',
    LOG_FORMAT,
    '-n',
    String(count),
    before ?? 'HEAD',
    '--',
  ])
  if (log.code !== 0) {
    throw new HostError('not_found', `there is no commit ${before ?? 'HEAD'} in this repository`)
  }
  const commits: Commit[] = log.stdout
    .split('\x1e')
    .filter((record) => record.trim() !== '')
    .map((record) => {
      const newline = record.indexOf('\n')
      const fields = newline === -1 ? record : record.slice(0, newline)
      const stat = newline === -1 ? '' : record.slice(newline + 1)
      const [hash = '', subject = '', author = '', time = ''] = fields.split('\x1f')
      return { hash, subject, author, time, ...shortstat(stat) }
    })
  const listed = before === undefined ? commits : commits.slice(1)
  return { repository: true, commits: listed.slice(0, limit), more: listed.length > limit }
}

// What a commit changed against its first parent, or against the empty tree for the first commit
// of a repository. Without a path: the patch of the files that already existed, and the new files
// by path and number of lines; with a path, that file's whole patch.
export async function commitChanges(
  folder: string,
  commit: string,
  path?: string,
): Promise<FolderChanges> {
  checkCommitId(commit)
  if (path?.includes('\0')) throw new HostError('bad_request', 'the path holds a NUL')
  if (!(await inRepository(folder))) return { repository: false, patch: '', added: [], head: null }
  const tree = await git(folder, ['rev-parse', '--verify', '--quiet', `${commit}^{commit}^{tree}`])
  if (tree.code !== 0) {
    throw new HostError('not_found', `there is no commit ${commit} in this repository`)
  }
  const parent = await git(folder, ['rev-parse', '--verify', '--quiet', `${commit}^1^{tree}`])
  let before = parent.stdout.trim()
  if (parent.code !== 0 || before === '') {
    // The first commit: git writes the empty tree, whatever hash the repository uses.
    const empty = await git(folder, ['mktree'])
    if (empty.code !== 0) throw new HostError('unavailable', 'git could not make the empty tree')
    before = empty.stdout.trim()
  }
  const changes = await diffTrees(folder, before, tree.stdout.trim(), path)
  return { repository: true, ...changes, head: await headPosition(folder) }
}
