import { describe, expect, it } from 'vitest'
import type { AppConfig, CliResult } from '../shared/transport.ts'
import type { CliRun } from './cli.ts'
import { addProject, listProjects, loadProjects, ProjectRefused } from './projects.ts'

const config = { workDir: null, definitionPaths: [], env: {} } as unknown as AppConfig

// A program that answers each call with the next of `results`, and keeps what it was asked.
function program(...results: CliResult[]) {
  const calls: CliRun[] = []
  const run = (request: CliRun) => {
    calls.push(request)
    return Promise.resolve(results.shift() ?? { code: 0, stdout: '', stderr: '' })
  }
  return { calls, run }
}

const listing = (file: string | null, projects: object[]): CliResult => ({
  code: 0,
  stdout: JSON.stringify({ format: 'synapse-projects/v1', file, projects }),
  stderr: '',
})

const refused = async (action: Promise<unknown>): Promise<ProjectRefused> => {
  const error = await action.then(
    () => null,
    (e: unknown) => e,
  )
  expect(error).toBeInstanceOf(ProjectRefused)
  return error as ProjectRefused
}

describe('the projects', () => {
  it('are asked of synapse as JSON, with the file they are in', async () => {
    const { calls, run } = program(
      listing('/c/synapse-projects.conf', [{ name: 'synapse', prefix: 'sb' }]),
    )
    expect(await loadProjects(run, config)).toEqual({
      projects: [{ name: 'synapse', prefix: 'sb' }],
      file: '/c/synapse-projects.conf',
    })
    expect(calls[0]).toMatchObject({ binary: 'synapse', args: ['projects', '--format', 'json'] })
  })

  it('have no file named when there is no home to put one in, and are only the pairs when listed', async () => {
    const { run } = program(listing(null, []), listing('/f', [{ name: 'a', prefix: 'b' }]))
    expect(await loadProjects(run, config)).toEqual({ projects: [], file: '' })
    expect(await listProjects(run, config)).toEqual([{ name: 'a', prefix: 'b' }])
  })

  it('are refused, as a failure of what the app depends on, when synapse fails or answers oddly', async () => {
    const failed = program({
      code: 1,
      stdout: '',
      stderr: "synapse: unknown subcommand 'projects'\n",
    })
    const error = await refused(loadProjects(failed.run, config))
    expect(error.code).toBe('unavailable')
    expect(error.message).toBe("synapse: unknown subcommand 'projects'")

    const text = program({ code: 0, stdout: 'not json', stderr: '' })
    expect((await refused(loadProjects(text.run, config))).code).toBe('unavailable')
    const other = program({
      code: 0,
      stdout: JSON.stringify({ format: 'synapse-projects/v2', file: null, projects: [] }),
      stderr: '',
    })
    expect((await refused(loadProjects(other.run, config))).message).toContain('does not know')
  })
})

describe('adding a project', () => {
  it('is asked of synapse, which checks it, and answers with the projects there are now', async () => {
    const { calls, run } = program(
      { code: 0, stdout: '/c/synapse-projects.conf\n', stderr: '' },
      listing('/c/synapse-projects.conf', [{ name: 'thing', prefix: 'tg' }]),
    )
    expect(await addProject(run, config, 'thing', 'tg')).toEqual({
      projects: [{ name: 'thing', prefix: 'tg' }],
      file: '/c/synapse-projects.conf',
    })
    expect(calls[0]?.args).toEqual(['projects', 'add', 'thing', 'tg'])
    expect(calls).toHaveLength(2)
  })

  it('is refused with what synapse said, without its name in front of it, and nothing is listed after', async () => {
    const { calls, run } = program({
      code: 1,
      stdout: '',
      stderr: 'synapse-projects: thing is already a project, with the prefix tg.\n',
    })
    const error = await refused(addProject(run, config, 'thing', 'other'))
    expect(error.code).toBe('conflict')
    expect(error.message).toBe('thing is already a project, with the prefix tg.')
    expect(calls).toHaveLength(1)
  })

  it('has a reason of its own when synapse said nothing', async () => {
    const { run } = program({ code: 1, stdout: '', stderr: '' })
    expect((await refused(addProject(run, config, 'a', 'b'))).message).toBe(
      'synapse projects failed',
    )
  })
})
