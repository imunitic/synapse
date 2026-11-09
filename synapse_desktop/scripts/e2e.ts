// Runs the end-to-end tests: makes the world they run in, starts the app on it
// with the programs built in this checkout and the scripted runner (which costs
// nothing), runs Playwright and removes the world.

import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join, resolve } from 'node:path'
import { buildWorld, environmentFor } from '../e2e/world.ts'

const repo = resolve(import.meta.dirname, '..', '..')
const cliBin = join(repo, 'synapse_cli', 'bin')
const pipelineBin = join(repo, 'synapse_pipeline', 'bin')
const binDirs = [cliBin, pipelineBin]
const exe = process.platform === 'win32' ? '.exe' : ''
for (const program of [
  join(cliBin, `synapse${exe}`),
  join(cliBin, `synapse-hook${exe}`),
  join(pipelineBin, `synapse-pipeline${exe}`),
]) {
  if (!existsSync(program)) {
    console.error(`${program} is missing: run \`just build\` first.`)
    process.exit(1)
  }
}

// A run's socket path may not pass 100 bytes, so the root is short.
const root = mkdtempSync(join(process.platform === 'win32' ? tmpdir() : '/tmp', 'sd-e2e-'))
if (!basename(root).startsWith('sd-e2e-')) throw new Error('the world is not where it was made')

try {
  const world = buildWorld(root, binDirs)
  const cli = join('node_modules', '@playwright', 'test', 'cli.js')
  const result = spawnSync(process.execPath, [cli, 'test', ...process.argv.slice(2)], {
    stdio: 'inherit',
    env: {
      ...environmentFor(world, binDirs),
      E2E_WORLD: root,
      E2E_HOME: world.home,
      E2E_DATA: world.data,
    },
  })
  process.exitCode = result.status ?? 1
} finally {
  rmSync(root, { recursive: true, force: true })
}
