import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { defaultConfig } from '../shared/calls.ts'
import type { AppConfig, CliResult } from '../shared/transport.ts'
import type { CliRun } from './cli.ts'
import { findGraphRepos, searchRoots } from './graph-find.ts'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-find-'))
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

// A checkout is a folder with `.git`, a folder or, as in a worktree, a file.
async function checkout(name: string, worktree = false): Promise<string> {
  const path = join(dir, name)
  await mkdir(path, { recursive: true })
  if (worktree) await writeFile(join(path, '.git'), 'gitdir: elsewhere')
  else await mkdir(join(path, '.git'))
  return path
}

// Answers `namespace --repo <path>` with the key the folder is said to be on.
function runner(keys: Record<string, string>) {
  const asked: string[] = []
  return {
    asked,
    run: (r: CliRun): Promise<CliResult> => {
      const path = r.args[2] ?? ''
      asked.push(path)
      const key = keys[path]
      return Promise.resolve(
        key === undefined
          ? { code: 1, stdout: '', stderr: 'not a repository' }
          : { code: 0, stdout: `${key}\n`, stderr: '' },
      )
    },
  }
}

const withRepos = (repos: Record<string, string>, folder: string | null = null): AppConfig => ({
  ...defaultConfig,
  graphRepos: repos,
  terminalFolder: folder,
})

describe('finding the checkout of a graph', () => {
  it('looks next to the checkouts already saved, worktrees included', async () => {
    const main = await checkout('main')
    const feature = await checkout('feature', true)
    await mkdir(join(dir, 'notes'))
    const { run, asked } = runner({ [main]: 'widget@main', [feature]: 'widget@feature' })
    const config = withRepos({ 'widget@main': main })

    expect(await findGraphRepos(run, config, 'widget@feature')).toEqual([feature])
    expect(await findGraphRepos(run, config, 'widget@main')).toEqual([main])
    expect(await findGraphRepos(run, config, 'widget@gone')).toEqual([])
    // A folder that is not a checkout is never asked.
    expect(asked.some((path) => path.endsWith('notes'))).toBe(false)
  })

  it('lists every checkout that is on the namespace, in order', async () => {
    const b = await checkout('b')
    const a = await checkout('a')
    const { run } = runner({ [a]: 'widget@main', [b]: 'widget@main' })
    expect(await findGraphRepos(run, withRepos({ 'widget@main': a }), 'widget@main')).toEqual([
      a,
      b,
    ])
  })

  it('looks in the folder the terminals start in, and in nothing when there is none', async () => {
    const one = await checkout('one')
    const { run } = runner({ [one]: 'widget@main' })
    expect(await findGraphRepos(run, withRepos({}, dir), 'widget@main')).toEqual([one])
    expect(await findGraphRepos(run, withRepos({}), 'widget@main')).toEqual([])
    expect(searchRoots(withRepos({}, 'relative/path'))).toEqual([])
  })

  it('skips a folder that is not on any namespace', async () => {
    const odd = await checkout('odd')
    const { run } = runner({})
    expect(await findGraphRepos(run, withRepos({ 'a@b': odd }), 'a@b')).toEqual([])
  })
})
