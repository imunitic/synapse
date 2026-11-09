// Finding the checkout a graph was built from, so that its folder need not be typed.
// A graph is named `<repo>@<branch>` and the checkout on that branch is somewhere on
// this machine; the places to look are next to the checkouts already saved for other
// graphs, where worktrees and clones of one project are kept, and in the folder the
// terminals start in.

import { readdir, stat } from 'node:fs/promises'
import { dirname, isAbsolute, join } from 'node:path'
import type { AppConfig } from '../shared/transport.ts'
import type { CliRunner } from './cli.ts'
import { checkGraphRepo } from './graph-health.ts'

// How many folders are asked for their namespace, and how many at a time.
const MOST_CANDIDATES = 60
const AT_ONCE = 6

// The folders whose subfolders are looked through.
export function searchRoots(config: AppConfig): string[] {
  const roots = new Set<string>()
  for (const repo of Object.values(config.graphRepos)) roots.add(dirname(repo))
  if (config.terminalFolder !== null && isAbsolute(config.terminalFolder)) {
    roots.add(config.terminalFolder)
  }
  return [...roots]
}

// A git checkout has `.git`, a folder or, for a worktree, a file.
async function isCheckout(path: string): Promise<boolean> {
  return (await stat(join(path, '.git')).catch(() => null)) !== null
}

async function subfolders(root: string): Promise<string[]> {
  const entries = await readdir(root, { withFileTypes: true }).catch(() => [])
  return entries
    .filter((e) => e.isDirectory() && !e.name.startsWith('.') && e.name !== 'node_modules')
    .map((e) => join(root, e.name))
}

async function candidates(config: AppConfig): Promise<string[]> {
  const found = new Set<string>()
  for (const root of searchRoots(config)) {
    for (const path of [root, ...(await subfolders(root))]) {
      if (found.size >= MOST_CANDIDATES) break
      if (await isCheckout(path)) found.add(path)
    }
  }
  return [...found]
}

// The checkouts that are on the namespace now, in name order.
export async function findGraphRepos(
  run: CliRunner,
  config: AppConfig,
  namespace: string,
): Promise<string[]> {
  const paths = await candidates(config)
  const matches: string[] = []
  for (let at = 0; at < paths.length; at += AT_ONCE) {
    const chunk = paths.slice(at, at + AT_ONCE)
    const checks = await Promise.all(chunk.map((path) => checkGraphRepo(run, config, path)))
    chunk.forEach((path, i) => {
      if (checks[i]?.key === namespace) matches.push(path)
    })
  }
  return matches.sort((a, b) => a.localeCompare(b))
}
