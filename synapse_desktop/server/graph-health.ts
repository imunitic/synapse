// Asking a code graph how it stands against the repository it was built from:
// which nodes are stale, what has drifted and what is no longer grounded. These
// read the real files of the repository, which `synapse` is told the folder of.

import { isAbsolute } from 'node:path'
import type {
  AppConfig,
  GraphCheck,
  GraphFinding,
  GraphHealth,
  GraphRepoCheck,
} from '../shared/transport.ts'
import type { CliRunner } from './cli.ts'
import { isDirectory } from './fs-checks.ts'

// The rows of a check: a node's name, a tab and what is wrong with it. Nothing is
// printed when nothing is.
export function parseFindings(text: string): GraphFinding[] {
  return text
    .split('\n')
    .filter((line) => line !== '')
    .map((line) => {
      const tab = line.indexOf('\t')
      return tab < 0
        ? { node: line, reason: '' }
        : { node: line.slice(0, tab), reason: line.slice(tab + 1) }
    })
}

// The `<repo>@<branch>` of a folder as it is checked out now.
export async function checkGraphRepo(
  run: CliRunner,
  config: AppConfig,
  path: string,
): Promise<GraphRepoCheck> {
  if (!isAbsolute(path) || !(await isDirectory(path))) {
    return { key: null, error: `${path} is not a folder` }
  }
  const result = await run({ binary: 'synapse', args: ['namespace', '--repo', path], config })
  const key = result.stdout.trim()
  if (result.code === 0 && key !== '') return { key, error: null }
  const why = (result.stderr || result.stdout).trim()
  return { key: null, error: why === '' ? 'that folder has no namespace' : why }
}

async function check(
  run: CliRunner,
  config: AppConfig,
  namespace: string,
  repo: string,
  subcommand: 'stale' | 'drift' | 'grounding',
): Promise<GraphCheck> {
  const result = await run({
    binary: 'synapse',
    args: ['query', '--namespace', namespace, subcommand],
    config,
    env: { SYNAPSE_REPO_ROOT: repo },
  })
  // Exit 1 means it could not run, never that all is clean.
  if (result.code !== 0) {
    const why = (result.stderr || result.stdout).trim()
    return { ok: false, error: why === '' ? `${subcommand} could not run` : why }
  }
  return { ok: true, findings: parseFindings(result.stdout) }
}

export async function graphHealth(
  run: CliRunner,
  config: AppConfig,
  namespace: string,
  repo: string,
): Promise<GraphHealth> {
  const [stale, drift, grounding] = await Promise.all(
    (['stale', 'drift', 'grounding'] as const).map((sub) =>
      check(run, config, namespace, repo, sub),
    ),
  )
  return {
    stale: stale as GraphCheck,
    drift: drift as GraphCheck,
    grounding: grounding as GraphCheck,
  }
}
