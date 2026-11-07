// A throwaway copy of the definitions with a draft among them, so that the
// program, which reads files, can be asked about text that is not saved yet.

import { copyFile, mkdir, mkdtemp, readdir, rm, stat, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'

export interface SandboxFile {
  // The name of the definition: the file is `<name>.synapse`.
  name: string
  text: string
}

export interface SandboxInput {
  // The default definition directory, where the draft goes.
  defaultDir: string
  // The other directories definitions are looked for in.
  otherDirs: readonly string[]
  skillsDir: string | null
  draft: SandboxFile
  // A file that is there for the program to be asked about, when the draft is
  // not itself something the program can be asked about.
  extra?: SandboxFile
}

export interface Sandbox {
  // The variables that make the program read the copy and not the real files.
  env: { XDG_CONFIG_HOME: string; SYNAPSE_PIPELINE_PATH: string }
  cleanup: () => Promise<void>
}

// Copies the .synapse files directly in `from` into `to`, leaving out the one
// called `skip`. A directory that is not there has none.
async function copyDefinitions(from: string, to: string, skip: string): Promise<void> {
  await mkdir(to, { recursive: true })
  const entries = await readdir(from, { withFileTypes: true }).catch(() => [])
  for (const entry of entries) {
    if (!entry.name.endsWith('.synapse') || entry.name === skip) continue
    // A link to a file counts as the file.
    const info = await stat(join(from, entry.name)).catch(() => null)
    if (info?.isFile()) await copyFile(join(from, entry.name), join(to, entry.name))
  }
}

export async function buildSandbox(input: SandboxInput): Promise<Sandbox> {
  const root = await mkdtemp(join(tmpdir(), 'synapse-desktop-draft-'))
  try {
    const configRoot = join(root, 'xdg')
    const defaultCopy = join(configRoot, 'synapse-pipeline')
    const draftFile = `${input.draft.name}.synapse`

    // The draft replaces the file of its name in the directory it is saved to.
    await copyDefinitions(input.defaultDir, defaultCopy, draftFile)
    await writeFile(join(defaultCopy, draftFile), input.draft.text)
    if (input.extra !== undefined) {
      await writeFile(join(defaultCopy, `${input.extra.name}.synapse`), input.extra.text)
    }

    const others: string[] = []
    for (const [i, dir] of input.otherDirs.entries()) {
      const copy = join(root, `dir${i}`)
      await copyDefinitions(dir, copy, '')
      others.push(copy)
    }

    // The skills are read, never changed, so they are linked and not copied.
    if (input.skillsDir !== null) {
      await symlink(input.skillsDir, join(defaultCopy, 'skills'), 'dir')
    }

    return {
      env: { XDG_CONFIG_HOME: configRoot, SYNAPSE_PIPELINE_PATH: others.join(delimiter) },
      cleanup: () => rm(root, { recursive: true, force: true }),
    }
  } catch (error) {
    await rm(root, { recursive: true, force: true })
    throw error
  }
}
