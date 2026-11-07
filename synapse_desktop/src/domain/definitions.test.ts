import { describe, expect, it } from 'vitest'
import {
  kindOfSource,
  listDefinitions,
  listRecordedDefinitions,
  listSkills,
} from './definitions.ts'
import { fakeTransport } from './fake-transport.ts'

describe('kindOfSource', () => {
  it('reads the first word', () => {
    expect(kindOfSource('Pipeline P { A; }')).toBe('pipeline')
    expect(kindOfSource('System S [Agent => A];')).toBe('system')
    expect(kindOfSource('Agent A [Prompt => "x"];')).toBe('agent')
  })

  it('skips comments and blank lines before it', () => {
    expect(kindOfSource('-- Build a change.\n\n  -- more\nPipeline P {}')).toBe('pipeline')
  })

  it('is case-sensitive and needs the whole word', () => {
    expect(kindOfSource('pipeline P {}')).toBeNull()
    expect(kindOfSource('Pipelines P {}')).toBeNull()
  })

  it('finds no kind in an empty file, a comment only, or a word that is not a kind', () => {
    expect(kindOfSource('')).toBeNull()
    expect(kindOfSource('-- nothing here')).toBeNull()
    expect(kindOfSource('constructor X')).toBeNull()
  })
})

describe('listDefinitions', () => {
  const paths = { definitionDirs: ['/a', '/b'], skillsDir: null, recordsDir: null }

  it('lists the .synapse files of every directory by name and kind', async () => {
    const transport = fakeTransport({
      paths,
      files: {
        '/a/Develop.synapse': '-- c\nPipeline Develop {}',
        '/a/Reviewer.synapse': 'Agent Reviewer [Prompt => "x"];',
        '/a/notes.txt': 'not a definition',
        '/b/Strict.synapse': 'System Strict [Agent => Reviewer];',
      },
    })
    const found = await listDefinitions(transport)
    expect(found.map((d) => [d.name, d.kind, d.path])).toEqual([
      ['Develop', 'pipeline', '/a/Develop.synapse'],
      ['Reviewer', 'agent', '/a/Reviewer.synapse'],
      ['Strict', 'system', '/b/Strict.synapse'],
    ])
    expect(found.every((d) => !d.duplicate)).toBe(true)
  })

  it('marks a name claimed by two files, whatever their kinds', async () => {
    const transport = fakeTransport({
      paths,
      files: { '/a/X.synapse': 'Agent X [Prompt => "x"];', '/b/X.synapse': 'System X [];' },
    })
    const found = await listDefinitions(transport)
    expect(found).toHaveLength(2)
    expect(found.every((d) => d.duplicate)).toBe(true)
  })

  it('leaves out a file that does not start with a kind', async () => {
    const transport = fakeTransport({
      paths: { ...paths, definitionDirs: ['/a'] },
      files: { '/a/Odd.synapse': 'Widget Odd {}' },
    })
    expect(await listDefinitions(transport)).toEqual([])
  })
})

describe('listSkills', () => {
  it('lists the directories that hold a SKILL.md', async () => {
    const transport = fakeTransport({
      paths: { definitionDirs: [], skillsDir: '/s', recordsDir: null },
      files: {
        '/s/test-feature/SKILL.md': '---\nname: test-feature\n---',
        '/s/test-feature/notes.md': 'x',
        '/s/empty/readme.md': 'no skill file',
      },
    })
    expect(await listSkills(transport)).toEqual([
      { name: 'test-feature', path: '/s/test-feature/SKILL.md' },
    ])
  })

  it('finds none without a skills directory', async () => {
    const transport = fakeTransport({
      paths: { definitionDirs: [], skillsDir: null, recordsDir: null },
      files: {},
    })
    expect(await listSkills(transport)).toEqual([])
  })
})

describe('listRecordedDefinitions', () => {
  const paths = { definitionDirs: [], skillsDir: null, recordsDir: '/w/pipelines' }
  const dir = '/w/pipelines/exec-1/definitions/synapse-pipeline'

  it('lists the files a run kept, by name and kind, with its skills', async () => {
    const transport = fakeTransport({
      paths,
      files: {
        [`${dir}/Dev.synapse`]: 'Pipeline Dev {}',
        [`${dir}/Reviewer.synapse`]: 'Agent Reviewer [Prompt => "x"];',
        [`${dir}/skills/review-code/SKILL.md`]: '---\nname: review-code\n---',
      },
    })
    const kept = await listRecordedDefinitions(transport, 'exec-1')
    expect(kept.definitions.map((d) => [d.name, d.kind])).toEqual([
      ['Dev', 'pipeline'],
      ['Reviewer', 'agent'],
    ])
    expect(kept.skills.map((s) => s.name)).toEqual(['review-code'])
  })

  it('has nothing for a record made before it kept them, or without a work directory', async () => {
    const old = fakeTransport({ paths, files: { '/w/pipelines/exec-1/execution.json': '{}' } })
    expect(await listRecordedDefinitions(old, 'exec-1')).toEqual({ definitions: [], skills: [] })
    const none = fakeTransport({
      paths: { definitionDirs: [], skillsDir: null, recordsDir: null },
      files: {},
    })
    expect(await listRecordedDefinitions(none, 'exec-1')).toEqual({ definitions: [], skills: [] })
  })

  it('does not mix the files of two runs', async () => {
    const transport = fakeTransport({
      paths,
      files: {
        [`${dir}/Dev.synapse`]: 'Pipeline Dev {}',
        '/w/pipelines/exec-2/definitions/synapse-pipeline/Other.synapse': 'Pipeline Other {}',
      },
    })
    const kept = await listRecordedDefinitions(transport, 'exec-1')
    expect(kept.definitions.map((d) => d.name)).toEqual(['Dev'])
  })
})
