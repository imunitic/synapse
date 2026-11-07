import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  addProject,
  listProjects,
  parseProjects,
  ProjectRefused,
  projectsFile,
  refusalFor,
} from './projects.ts'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-projects-'))
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

const environment = (xdg?: string) => ({
  env: xdg === undefined ? {} : { XDG_CONFIG_HOME: xdg },
  home: dir,
})

describe('the projects file', () => {
  it('is the one under XDG_CONFIG_HOME, else ~/.config, when there is one', async () => {
    const xdg = join(dir, 'xdg')
    await mkdir(join(xdg, 'synapse'), { recursive: true })
    await writeFile(join(xdg, 'synapse', 'synapse-projects.conf'), 'a=b\n')
    expect(await projectsFile(environment(xdg))).toBe(join(xdg, 'synapse', 'synapse-projects.conf'))

    await mkdir(join(dir, '.config', 'synapse'), { recursive: true })
    await writeFile(join(dir, '.config', 'synapse', 'synapse-projects.conf'), 'c=d\n')
    expect(await projectsFile(environment())).toBe(
      join(dir, '.config', 'synapse', 'synapse-projects.conf'),
    )
  })

  it('falls back to ~/.claude, and is made in the first place when there is none', async () => {
    await mkdir(join(dir, '.claude'), { recursive: true })
    await writeFile(join(dir, '.claude', 'synapse-projects.conf'), 'a=b\n')
    expect(await projectsFile(environment())).toBe(join(dir, '.claude', 'synapse-projects.conf'))

    await rm(join(dir, '.claude'), { recursive: true })
    // No ~/.config here, so the file would be in ~/.claude; with one it is in ~/.config/synapse.
    expect(await projectsFile(environment())).toBe(join(dir, '.claude', 'synapse-projects.conf'))
    await mkdir(join(dir, '.config'))
    expect(await projectsFile(environment())).toBe(
      join(dir, '.config', 'synapse', 'synapse-projects.conf'),
    )
  })
})

describe('the pairs in the file', () => {
  it('are the name=prefix lines, without comments and blank lines', () => {
    expect(parseProjects('# note\n\nsynapse=sb\n  eon = ecs  \nbad line\n=x\ny=\n')).toEqual([
      { name: 'synapse', prefix: 'sb' },
      { name: 'eon', prefix: 'ecs' },
    ])
  })

  it('are listed from the file there is, and none without one', async () => {
    expect(await listProjects(environment())).toEqual([])
    await mkdir(join(dir, '.config', 'synapse'), { recursive: true })
    await writeFile(join(dir, '.config', 'synapse', 'synapse-projects.conf'), '# c\nsynapse=sb\n')
    expect(await listProjects(environment())).toEqual([{ name: 'synapse', prefix: 'sb' }])
  })
})

describe('adding a project', () => {
  const known = [{ name: 'synapse', prefix: 'sb' }]

  it('refuses a name or a prefix that is not one, and one that is taken', () => {
    expect(refusalFor('Synapse', 'sb2', [])).toMatch(/lower case/)
    expect(refusalFor('has space', 'sb2', [])).toMatch(/lower case/)
    expect(refusalFor('thing', '1x', [])).toMatch(/starts with a letter/)
    expect(refusalFor('thing', 'x-', [])).toMatch(/hyphen/)
    expect(refusalFor('synapse', 'zz', known)).toMatch(/already a project, with the prefix sb/)
    expect(refusalFor('thing', 'sb', known)).toMatch(/already the prefix of synapse/)
    expect(refusalFor('thing', 'tg', known)).toBeNull()
  })

  it('appends the pair on a line of its own, keeping what is there', async () => {
    const file = join(dir, '.config', 'synapse', 'synapse-projects.conf')
    await mkdir(join(dir, '.config', 'synapse'), { recursive: true })
    await writeFile(file, '# mine\nsynapse=sb')
    expect(await addProject(environment(), 'thing', 'tg')).toEqual([
      { name: 'synapse', prefix: 'sb' },
      { name: 'thing', prefix: 'tg' },
    ])
    expect(await readFile(file, 'utf8')).toBe('# mine\nsynapse=sb\nthing=tg\n')
  })

  it('makes the file when there is none, and refuses a second pair of the same name', async () => {
    await mkdir(join(dir, '.config'))
    await addProject(environment(), 'thing', 'tg')
    expect(await readFile(join(dir, '.config', 'synapse', 'synapse-projects.conf'), 'utf8')).toBe(
      'thing=tg\n',
    )
    const refused = await addProject(environment(), 'thing', 'other').then(
      () => null,
      (error: unknown) => error as ProjectRefused,
    )
    expect(refused).toBeInstanceOf(ProjectRefused)
    expect(refused?.status).toBe(409)
  })
})
