import { stat } from 'node:fs/promises'

// Whether a path is a folder that exists; a path that cannot be looked at is not one.
export async function isDirectory(path: string): Promise<boolean> {
  return (await stat(path).catch(() => null))?.isDirectory() ?? false
}
