// What a folder's working tree has changed since a snapshot of it: git's own view, taken without
// touching the repository. A snapshot is the id of a tree object, kept by whoever asks for the
// changes; the changes are the difference between it and the tree as it is now.

import { z } from 'zod'

// A git tree id: 40 hexadecimal digits, or 64 for a repository that uses SHA-256.
export const treeIdSchema = z.string().regex(/^[0-9a-f]{40}([0-9a-f]{24})?$/)

// A file that is new, which is listed by its path and its number of lines and has its content
// only when it is asked for. A binary file has no number of lines.
export const addedFileSchema = z.object({
  path: z.string(),
  lines: z.number().int().nonnegative().nullable(),
})

// Where HEAD is: the name of the branch checked out, the id of the commit when HEAD is detached, or
// null when the folder is not in a git repository. A snapshot is kept for each position, so that a
// branch switch starts a new comparison and switching back restores the old one.
export const headPositionSchema = z.string().min(1).nullable()

export const folderChangesSchema = z.object({
  // Whether the folder is in a git repository; when it is not there is nothing to show.
  repository: z.boolean(),
  // The unified diff of the files that already existed. For one file asked for by its path, that
  // file's diff, whether or not it is new.
  patch: z.string(),
  // The new files, when no one file was asked for.
  added: z.array(addedFileSchema),
  // Where HEAD is now, so that a client sees a branch switch when it next asks.
  head: headPositionSchema,
})

// A snapshot of a working tree and where HEAD was when it was taken.
export const snapshotSchema = z.object({
  tree: treeIdSchema.nullable(),
  head: headPositionSchema,
})

export type Snapshot = z.infer<typeof snapshotSchema>

// A commit named by the page: 7 to 64 hexadecimal digits, so that git never reads it as an option.
export const commitIdSchema = z.string().regex(/^[0-9a-f]{7,64}$/)

// A commit of the branch a session is on, as the Git tab lists it.
export const commitSchema = z.object({
  // The full hash.
  hash: z.string(),
  subject: z.string(),
  author: z.string(),
  // When it was committed, ISO 8601.
  time: z.string(),
  // The lines it added and removed, against its first parent; binary files have none to count.
  added: z.number().int().nonnegative(),
  removed: z.number().int().nonnegative(),
})

// The commits of HEAD, newest first, along the first parent: one page of them, and whether there
// are more. A folder that is not in a git repository has none.
export const commitLogSchema = z.object({
  repository: z.boolean(),
  commits: z.array(commitSchema),
  more: z.boolean(),
})

export type Commit = z.infer<typeof commitSchema>
export type CommitLog = z.infer<typeof commitLogSchema>

export type AddedFile = z.infer<typeof addedFileSchema>
export type FolderChanges = z.infer<typeof folderChangesSchema>

// The most a patch may hold: a change larger than this is refused, not cut.
export const MAX_PATCH_BYTES = 4 * 1024 * 1024
