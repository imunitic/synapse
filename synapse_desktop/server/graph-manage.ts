// Deleting a code graph, and cleaning up the graphs of branches that are gone.
// Both work on the repository a graph was built from, so they run in the folder
// saved for the namespace, and a drop is only done when that folder is on the
// namespace's own branch: `synapse graph-wipe` drops the graph of the checkout it
// is run in, and the wrong folder would drop another one.

import { stat } from 'node:fs/promises'
import type { AppConfig, GraphPlan } from '../shared/transport.ts'
import type { CliRunner } from './cli.ts'
import { checkGraphRepo } from './graph-health.ts'

// Why an action cannot be done, with the status the caller should see.
export class GraphActionRefused extends Error {
  status: number

  constructor(message: string, status = 409) {
    super(message)
    this.status = status
  }
}

// The folder saved for a namespace, which must exist.
async function repositoryOf(config: AppConfig, namespace: string): Promise<string> {
  const repo = config.graphRepos[namespace]
  if (repo === undefined) throw new GraphActionRefused('no repository is saved for this graph')
  if (!(await stat(repo).catch(() => null))?.isDirectory()) {
    throw new GraphActionRefused(`${repo} is not a folder`)
  }
  return repo
}

function lines(text: string): string[] {
  return text.split('\n').filter((line) => line !== '')
}

async function run(
  runner: CliRunner,
  config: AppConfig,
  repo: string,
  command: 'graph-wipe' | 'graph-clean',
  dry: boolean,
): Promise<string> {
  const result = await runner({
    binary: 'synapse',
    args: dry ? [command, '--dry-run'] : [command],
    config,
    cwd: repo,
  })
  if (result.code !== 0) {
    const why = (result.stderr || result.stdout).trim()
    throw new GraphActionRefused(why === '' ? `${command} failed` : why, 502)
  }
  return result.stdout
}

// The drop of a namespace's graph, which is only for the checkout that is on it.
async function dropRepository(
  runner: CliRunner,
  config: AppConfig,
  namespace: string,
): Promise<string> {
  const repo = await repositoryOf(config, namespace)
  const check = await checkGraphRepo(runner, config, repo)
  if (check.key !== namespace) {
    throw new GraphActionRefused(
      check.key === null
        ? `${repo} has no namespace: ${check.error ?? ''}`.trim()
        : `${repo} is on ${check.key}, not ${namespace}, so deleting from it would delete another graph`,
    )
  }
  return repo
}

export async function planGraphDrop(
  runner: CliRunner,
  config: AppConfig,
  namespace: string,
): Promise<GraphPlan> {
  const repo = await dropRepository(runner, config, namespace)
  return { lines: lines(await run(runner, config, repo, 'graph-wipe', true)) }
}

export async function dropGraph(
  runner: CliRunner,
  config: AppConfig,
  namespace: string,
): Promise<{ output: string }> {
  const repo = await dropRepository(runner, config, namespace)
  return { output: (await run(runner, config, repo, 'graph-wipe', false)).trim() }
}

export async function planGraphClean(
  runner: CliRunner,
  config: AppConfig,
  namespace: string,
): Promise<GraphPlan> {
  const repo = await repositoryOf(config, namespace)
  return { lines: lines(await run(runner, config, repo, 'graph-clean', true)) }
}

export async function cleanGraphs(
  runner: CliRunner,
  config: AppConfig,
  namespace: string,
): Promise<{ output: string }> {
  const repo = await repositoryOf(config, namespace)
  return { output: (await run(runner, config, repo, 'graph-clean', false)).trim() }
}
