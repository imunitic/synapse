// The projects the vault's notes belong to: `synapse-projects.conf`, a plain list of
// `name=prefix` lines on this machine. The name is the folder a project's notes are in
// (`tasks/<name>/`) and the prefix is in each note's `project` and its id (`sb-001`).
// `synapse projects` finds the file, reads it and checks what is added to it, as it does for the
// skills that use the same file; this asks it.

import { z } from 'zod'
import type { AppConfig, Project, ProjectList } from '../shared/transport.ts'
import type { CliRunner } from './cli.ts'
import { HostError } from '../shared/dispatch.ts'
import type { ErrorCode } from '../shared/protocol.ts'

export class ProjectRefused extends HostError {
  constructor(message: string, code: ErrorCode = 'bad_request') {
    super(code, message)
  }
}

const listingSchema = z.object({
  format: z.literal('synapse-projects/v1'),
  file: z.string().nullable(),
  projects: z.array(z.object({ name: z.string(), prefix: z.string() })),
})

// What the program says when it is refused, without its own name in front of it.
function reasonOf(stderr: string, stdout: string): string {
  const text = (stderr || stdout).trim()
  return text.replace(/^synapse-projects: /, '') || 'synapse projects failed'
}

// The projects there are, and the file they are in (the one that would be made, when there is none).
export async function loadProjects(run: CliRunner, config: AppConfig): Promise<ProjectList> {
  const result = await run({ binary: 'synapse', args: ['projects', '--format', 'json'], config })
  if (result.code !== 0)
    throw new ProjectRefused(reasonOf(result.stderr, result.stdout), 'unavailable')
  let json: unknown
  try {
    json = JSON.parse(result.stdout)
  } catch {
    throw new ProjectRefused(
      'synapse projects printed something this app does not know',
      'unavailable',
    )
  }
  const listing = listingSchema.safeParse(json)
  if (!listing.success) {
    throw new ProjectRefused(
      'synapse projects answered in a format this app does not know',
      'unavailable',
    )
  }
  return { projects: listing.data.projects, file: listing.data.file ?? '' }
}

export async function listProjects(run: CliRunner, config: AppConfig): Promise<Project[]> {
  return (await loadProjects(run, config)).projects
}

// Adds one pair, which the program checks first, and answers with the projects there are now.
export async function addProject(
  run: CliRunner,
  config: AppConfig,
  name: string,
  prefix: string,
): Promise<ProjectList> {
  const result = await run({ binary: 'synapse', args: ['projects', 'add', name, prefix], config })
  if (result.code !== 0)
    throw new ProjectRefused(reasonOf(result.stderr, result.stdout), 'conflict')
  return loadProjects(run, config)
}
