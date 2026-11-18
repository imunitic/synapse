// Copies what the desktop app brings with it into `src-tauri/resources`, from where Tauri bundles it:
// the native programs, which the harnesses and the app run by their plain names, and the folders with
// the skills, commands and harness files of the two packages. The programs are the ones built in
// this checkout (`just build`); a release builds them for the target and stages them the same way.

import { chmodSync, cpSync, existsSync, mkdirSync, readdirSync, rmSync } from 'node:fs'
import { join, resolve } from 'node:path'

const repo = resolve(import.meta.dirname, '..', '..')
const out = join(import.meta.dirname, '..', 'src-tauri', 'resources')
const exe = process.platform === 'win32' ? '.exe' : ''

const programs = [
  join(repo, 'synapse_cli', 'bin', `synapse${exe}`),
  join(repo, 'synapse_cli', 'bin', `synapse-hook${exe}`),
  join(repo, 'synapse_pipeline', 'bin', `synapse-pipeline${exe}`),
]
for (const program of programs) {
  if (!existsSync(program)) {
    console.error(`${program} is missing: run \`just build\` first.`)
    process.exit(1)
  }
}

rmSync(out, { recursive: true, force: true })
mkdirSync(join(out, 'bin'), { recursive: true })
for (const program of programs) {
  const target = join(
    out,
    'bin',
    program.slice(program.lastIndexOf(process.platform === 'win32' ? '\\' : '/') + 1),
  )
  cpSync(program, target)
  chmodSync(target, 0o755)
}

// What a package holds that is not its Node launcher: its skills, commands, harness files and templates.
const launcher = new Set(['bin', 'lib', 'platforms', 'package.json'])
for (const name of ['synapse', 'synapse-pipeline']) {
  const from = join(repo, 'packages', name)
  const to = join(out, 'packages', name)
  mkdirSync(to, { recursive: true })
  for (const entry of readdirSync(from)) {
    if (!launcher.has(entry)) cpSync(join(from, entry), join(to, entry), { recursive: true })
  }
}
console.log(`staged in ${out}`)
