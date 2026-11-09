// Switching the vault: what a folder looks like as a vault, and the vaults the
// app has used.

import type { VaultInfo } from '../../shared/transport.ts'

const MAX_RECENT = 8

// A folder in a sentence: whether it is there, how many notes it holds and
// whether it has an index and a git history.
export function describeVault(info: VaultInfo): string {
  if (!info.exists) return 'There is no folder at this path.'
  const notes = `${info.notes}${info.capped ? '+' : ''} ${info.notes === 1 && !info.capped ? 'note' : 'notes'}`
  return [
    `A folder with ${notes}`,
    info.hasIndex ? 'has an Index.md' : 'has no Index.md',
    info.isGit ? 'is a git repository' : 'is not a git repository',
  ].join(', ')
}

// A path the server can look at: absolute on any platform, or in the home folder,
// which the server knows.
export function isAbsolutePath(path: string): boolean {
  return (
    path.startsWith('/') ||
    /^[A-Za-z]:[\\/]/.test(path) ||
    path.startsWith('\\\\') ||
    path === '~' ||
    path.startsWith('~/') ||
    path.startsWith('~\\')
  )
}

// The recent vaults with this one first, once.
export function rememberVault(recent: readonly string[], path: string): string[] {
  return [path, ...recent.filter((p) => p !== path)].slice(0, MAX_RECENT)
}

// A variable's name, as every shell takes it.
export function isEnvName(name: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) && name.length <= 128
}

// The variables with this one set, in the order they were first set.
export function withVariable(
  env: Readonly<Record<string, string>>,
  name: string,
  value: string,
): Record<string, string> {
  return { ...env, [name]: value }
}

export function withoutVariable(
  env: Readonly<Record<string, string>>,
  name: string,
): Record<string, string> {
  return Object.fromEntries(Object.entries(env).filter(([key]) => key !== name))
}
