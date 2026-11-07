// A path a person types may start with `~` for their home folder, as in a shell.

import { join } from 'node:path'
import type { AppConfig } from '../shared/transport.ts'

// `~` and `~/rest` (`~\rest` too, on Windows) are the home folder and a path in it;
// anything else, including `~name`, is left as it was typed.
export function expandHome(path: string, home: string): string {
  if (home === '') return path
  if (path === '~') return home
  if (path.startsWith('~/') || path.startsWith('~\\')) return join(home, path.slice(2))
  return path
}

// The settings that hold a folder, with `~` in them expanded.
export function expandConfigPaths(config: AppConfig, home: string): AppConfig {
  return {
    ...config,
    workDir: config.workDir === null ? null : expandHome(config.workDir, home),
    definitionPaths: config.definitionPaths.map((path) => expandHome(path, home)),
    terminalFolder: config.terminalFolder === null ? null : expandHome(config.terminalFolder, home),
    graphRepos: Object.fromEntries(
      Object.entries(config.graphRepos).map(([key, path]) => [key, expandHome(path, home)]),
    ),
  }
}
