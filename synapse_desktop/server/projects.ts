// The projects the vault's notes belong to: `synapse-projects.conf`, a plain list of
// `name=prefix` lines on this machine. The name is the folder a project's notes are in
// (`tasks/<name>/`) and the prefix is in each note's `project` and its id (`sb-001`).
// The skills read and append to the same file, so it is found the way they find it.

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import type { Project } from '../shared/transport.ts'
import { confFile } from './conf-files.ts'
import type { Environment } from './roots.ts'

const FILE_NAME = 'synapse-projects.conf'

export class ProjectRefused extends Error {
  status: number

  constructor(message: string, status = 400) {
    super(message)
    this.status = status
  }
}

// The file that is read, else where one is made.
export function projectsFile(environment: Environment): Promise<string> {
  return confFile(environment, FILE_NAME)
}

// The pairs of the file, in order; comments and blank lines are left out.
export function parseProjects(text: string): Project[] {
  const projects: Project[] = []
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line === '' || line.startsWith('#')) continue
    const at = line.indexOf('=')
    if (at <= 0) continue
    const name = line.slice(0, at).trim()
    const prefix = line.slice(at + 1).trim()
    if (name !== '' && prefix !== '') projects.push({ name, prefix })
  }
  return projects
}

export async function listProjects(environment: Environment): Promise<Project[]> {
  const text = await readFile(await projectsFile(environment), 'utf8').catch(() => '')
  return parseProjects(text)
}

// A name is a folder, in lower case as the others are; a prefix starts a note id, which
// is `<prefix>-` and three digits or more.
const NAME = /^[a-z0-9][a-z0-9._-]{0,63}$/
const PREFIX = /^[a-z][a-z0-9-]{0,31}$/

export function refusalFor(name: string, prefix: string, known: readonly Project[]): string | null {
  if (!NAME.test(name)) {
    return 'A project name is lower case letters, digits, dots, underscores and hyphens, and starts with a letter or a digit.'
  }
  if (!PREFIX.test(prefix) || prefix.endsWith('-')) {
    return 'A prefix is lower case letters, digits and hyphens, starts with a letter and does not end with a hyphen.'
  }
  const taken = known.find((p) => p.name === name || p.prefix === prefix)
  if (taken !== undefined) {
    return taken.name === name
      ? `${name} is already a project, with the prefix ${taken.prefix}.`
      : `The prefix ${prefix} is already the prefix of ${taken.name}.`
  }
  return null
}

// Adds one pair to the file, which is made when there is none, and answers with the
// projects there are now.
export async function addProject(
  environment: Environment,
  name: string,
  prefix: string,
): Promise<Project[]> {
  const file = await projectsFile(environment)
  const before = await readFile(file, 'utf8').catch(() => '')
  const refusal = refusalFor(name, prefix, parseProjects(before))
  if (refusal !== null) throw new ProjectRefused(refusal, 409)
  await mkdir(dirname(file), { recursive: true })
  const separator = before === '' || before.endsWith('\n') ? '' : '\n'
  await writeFile(file, `${before}${separator}${name}=${prefix}\n`)
  return parseProjects(await readFile(file, 'utf8'))
}
