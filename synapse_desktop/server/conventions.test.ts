import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  addConvention,
  ConventionRefused,
  DEFINITIONS,
  listConventions,
  parseJson,
  parseLines,
  removeConvention,
} from './conventions.ts'

let dir: string
let xdg: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-conventions-'))
  xdg = join(dir, 'xdg')
  await mkdir(join(xdg, 'synapse'), { recursive: true })
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

const environment = () => ({ env: { XDG_CONFIG_HOME: xdg }, home: dir })
const fileOf = (name: string) => join(xdg, 'synapse', name)

async function one(id: string) {
  const found = (await listConventions(environment())).conventions.find((c) => c.id === id)
  if (found === undefined) throw new Error(`no card ${id}`)
  return found
}

async function refusal(promise: Promise<unknown>): Promise<ConventionRefused> {
  const error = await promise.then(
    () => null,
    (e: unknown) => e,
  )
  expect(error).toBeInstanceOf(ConventionRefused)
  return error as ConventionRefused
}

describe('the files there are', () => {
  it('are every one Synapse keeps, once each, each in a group', () => {
    const ids = DEFINITIONS.map((d) => d.id)
    expect(new Set(ids).size).toBe(ids.length)
    expect(new Set(DEFINITIONS.map((d) => d.file)).size).toBe(ids.length)
    expect(new Set(DEFINITIONS.map((d) => d.group))).toEqual(
      new Set(['Vault', 'Code graph', 'Prompts']),
    )
    for (const d of DEFINITIONS) expect(d.file).toMatch(/^synapse-.+\.conf$/)
  })

  it('are listed with where each is, also when it is not there yet', async () => {
    const { conventions } = await listConventions(environment())
    expect(conventions).toHaveLength(DEFINITIONS.length)
    const tags = conventions.find((c) => c.id === 'tags')
    expect(tags).toMatchObject({
      file: fileOf('synapse-tag-vocabulary.conf'),
      exists: false,
      entries: [],
      problem: null,
      editable: true,
    })
  })
})

describe('a file of lines', () => {
  it('has the lines that are not blank and not comments, trimmed', () => {
    expect(parseLines('# note\n\n  alpha \nbeta\n   # later\n\r\n')).toEqual(['alpha', 'beta'])
  })

  it('is listed with its entries, and its comments are not entries', async () => {
    await writeFile(fileOf('synapse-prompt-stopwords.conf'), '# words\nthe\n\nand\n')
    const card = await one('stopwords')
    expect(card.exists).toBe(true)
    expect(card.entries).toEqual([{ text: 'the' }, { text: 'and' }])
  })

  it('takes an entry on a new line, makes the file, and keeps what was there', async () => {
    const created = await addConvention(environment(), 'tags', 'alpha')
    expect(created.conventions.find((c) => c.id === 'tags')?.entries).toEqual([{ text: 'alpha' }])
    expect(await readFile(fileOf('synapse-tag-vocabulary.conf'), 'utf8')).toBe('alpha\n')

    await writeFile(fileOf('synapse-ignore-files.conf'), '# mine\nvendor/')
    await addConvention(environment(), 'ignore-files', '  dist/  ')
    expect(await readFile(fileOf('synapse-ignore-files.conf'), 'utf8')).toBe(
      '# mine\nvendor/\ndist/\n',
    )
  })

  it('refuses an entry that is empty, several lines, a comment or already there', async () => {
    await addConvention(environment(), 'tags', 'alpha')
    expect((await refusal(addConvention(environment(), 'tags', '   '))).status).toBe(409)
    expect((await refusal(addConvention(environment(), 'tags', 'a\nb'))).message).toContain(
      'one line',
    )
    expect((await refusal(addConvention(environment(), 'tags', '# hidden'))).message).toContain(
      'comment',
    )
    expect((await refusal(addConvention(environment(), 'tags', 'alpha'))).message).toContain(
      'already there',
    )
    expect(await readFile(fileOf('synapse-tag-vocabulary.conf'), 'utf8')).toBe('alpha\n')
  })

  it('loses only the entry that is taken out, comments and the rest as they were', async () => {
    await writeFile(fileOf('synapse-tag-vocabulary.conf'), '# keep\nalpha\n\nbeta\n# alpha\n')
    const after = await removeConvention(environment(), 'tags', 'alpha')
    expect(after.conventions.find((c) => c.id === 'tags')?.entries).toEqual([{ text: 'beta' }])
    expect(await readFile(fileOf('synapse-tag-vocabulary.conf'), 'utf8')).toBe(
      '# keep\n\nbeta\n# alpha\n',
    )
  })

  it('refuses to take out what is not there, and a file that is not there', async () => {
    expect((await refusal(removeConvention(environment(), 'tags', 'nope'))).status).toBe(404)
    await writeFile(fileOf('synapse-tag-vocabulary.conf'), 'alpha\n')
    expect((await refusal(removeConvention(environment(), 'tags', 'nope'))).status).toBe(404)
    expect((await refusal(removeConvention(environment(), 'tags', '# nope'))).status).toBe(404)
  })
})

describe('the projects', () => {
  it('are name=prefix lines, added through the rules of a project', async () => {
    await writeFile(fileOf('synapse-projects.conf'), '# mine\nsynapse=sb\n')
    const card = await one('projects')
    expect(card.entries).toEqual([{ text: 'synapse=sb' }])

    await addConvention(environment(), 'projects', 'thing = tg')
    expect(await readFile(fileOf('synapse-projects.conf'), 'utf8')).toBe(
      '# mine\nsynapse=sb\nthing=tg\n',
    )
    expect((await refusal(addConvention(environment(), 'projects', 'other=sb'))).message).toContain(
      'The prefix sb is already the prefix of synapse',
    )
    expect(
      (await refusal(addConvention(environment(), 'projects', 'No Good=ng'))).message,
    ).toContain('lower case')
    expect((await refusal(addConvention(environment(), 'projects', 'nopair'))).message).toContain(
      'name=prefix',
    )
  })

  it('can have one taken out', async () => {
    await writeFile(fileOf('synapse-projects.conf'), 'synapse=sb\neon=ecs\n')
    await removeConvention(environment(), 'projects', 'eon=ecs')
    expect(await readFile(fileOf('synapse-projects.conf'), 'utf8')).toBe('synapse=sb\n')
  })
})

describe('a file of JSON', () => {
  it('has for entries the keys of an object with their values, in order', () => {
    expect(parseJson('{"ml": {"repo": "x"}, "el": "lisp"}')).toEqual({
      entries: [
        { text: 'ml', detail: '{"repo":"x"}' },
        { text: 'el', detail: '"lisp"' },
      ],
    })
  })

  it('has for entries the rules of a list, numbered in the order they are tried', () => {
    expect(parseJson('[{"match": "a"}, {"match": "b"}]')).toEqual({
      entries: [
        { text: '1', detail: '{"match":"a"}' },
        { text: '2', detail: '{"match":"b"}' },
      ],
    })
  })

  it('is empty when the file is, and says what is wrong when it is not JSON or a bare value', () => {
    expect(parseJson('  \n')).toEqual({ entries: [] })
    expect(parseJson('{"a": ')).toMatchObject({ problem: expect.stringContaining('not JSON') })
    expect(parseJson('3')).toEqual({ problem: 'It is neither an object nor a list.' })
  })

  it('is shown, with a problem when it is broken, and is never changed here', async () => {
    await writeFile(fileOf('synapse-grammars.conf'), '{"ml": {"repo": "x"}}')
    await writeFile(fileOf('synapse-fence-languages.conf'), '{oops')
    const grammars = await one('grammars')
    expect(grammars).toMatchObject({ editable: false, problem: null })
    expect(grammars.entries).toEqual([{ text: 'ml', detail: '{"repo":"x"}' }])
    expect(await one('fence-languages')).toMatchObject({
      editable: false,
      entries: [],
      problem: expect.stringContaining('not JSON'),
    })
    expect((await refusal(addConvention(environment(), 'grammars', 'x'))).status).toBe(409)
    expect((await refusal(removeConvention(environment(), 'grammars', 'ml'))).status).toBe(409)
    expect(await readFile(fileOf('synapse-grammars.conf'), 'utf8')).toBe('{"ml": {"repo": "x"}}')
  })

  it('is refused for an id that is not a file', async () => {
    expect((await refusal(addConvention(environment(), 'nothing', 'x'))).status).toBe(404)
  })
})
