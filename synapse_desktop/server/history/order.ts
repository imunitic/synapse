// The most recently used first; those with no time keep the order they came in, after.
export function newestFirst<T extends { lastUsed: string | null }>(found: readonly T[]): T[] {
  const dated = found.filter((w) => w.lastUsed !== null)
  const undated = found.filter((w) => w.lastUsed === null)
  dated.sort((a, b) => (b.lastUsed ?? '').localeCompare(a.lastUsed ?? ''))
  return [...dated, ...undated]
}

export const MAX_WORKSPACES = 50

// How many sessions are listed for a harness, and how many of the newest files are looked into
// to find them.
export const MAX_SESSIONS = 20
export const CANDIDATES = 2 * MAX_SESSIONS

// The first words of a prompt, as a title: one line, cut at a length that fits a row.
export function titleOf(text: string): string | null {
  const line = text.replace(/\s+/g, ' ').trim()
  if (line === '') return null
  return line.length > 90 ? `${line.slice(0, 89)}…` : line
}

// The start of a file, as text: at most `bytes` of it, so that a session file of many
// megabytes is not read in full.
export async function head(path: string, bytes: number): Promise<string> {
  const { open } = await import('node:fs/promises')
  const file = await open(path, 'r')
  try {
    const buffer = Buffer.alloc(bytes)
    const { bytesRead } = await file.read(buffer, 0, bytes, 0)
    return buffer.subarray(0, bytesRead).toString('utf8')
  } finally {
    await file.close()
  }
}

// A line of JSON that is not too long to be worth reading, or null.
export function jsonLine(line: string, longest = 200_000): Record<string, unknown> | null {
  if (line.length > longest || !line.startsWith('{')) return null
  try {
    const value: unknown = JSON.parse(line)
    return typeof value === 'object' && value !== null && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null
  } catch {
    return null
  }
}
