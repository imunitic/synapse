import { describe, expect, it } from 'vitest'
import {
  kindOfSource,
  listDefinitions,
  listRecordedDefinitions,
  loadDefinitions,
} from './definitions.ts'
import { fakeTransport } from './fake-transport.ts'

describe('kindOfSource', () => {
  it('reads the first word', () => {
    expect(kindOfSource('Pipeline P { A; }')).toBe('pipeline')
    expect(kindOfSource('System S [Agent => A];')).toBe('system')
    expect(kindOfSource('Agent A [Prompt => "x"];')).toBe('agent')
    expect(kindOfSource('Prompt P [Prompt => "x"];')).toBe('prompt')
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

describe('loadDefinitions', () => {
  const answered = (text: string, code = 0, stderr = '') =>
    fakeTransport({
      paths: { definitionDirs: [], recordsDir: null },
      files: {},
      cli: (binary, args) => {
        expect([binary, ...args]).toEqual(['synapse-pipeline', 'definitions', '--format', 'json'])
        return { code, stdout: text, stderr }
      },
    })

  const listing = JSON.stringify({
    format: 'synapse-pipeline-definitions/v1',
    definitions: [
      { kind: 'pipeline', name: 'Develop', file: '/a/Develop.synapse' },
      { kind: 'agent', name: 'Reviewer', file: '/a/Reviewer.synapse' },
      { kind: 'system', name: 'Strict', file: '/b/Strict.synapse' },
    ],
    problems: [{ file: '/a/Broken.synapse', line: 1, column: 22, message: 'expected a name' }],
  })

  it('has the definitions the CLI lists, by name, kind and file', async () => {
    const found = await loadDefinitions(answered(listing))
    expect(found.definitions).toEqual([
      { name: 'Develop', kind: 'pipeline', path: '/a/Develop.synapse', description: null },
      { name: 'Reviewer', kind: 'agent', path: '/a/Reviewer.synapse', description: null },
      { name: 'Strict', kind: 'system', path: '/b/Strict.synapse', description: null },
    ])
  })

  it('has a prompt in the listing as a prompt, with its description', async () => {
    const withPrompt = JSON.stringify({
      format: 'synapse-pipeline-definitions/v1',
      definitions: [
        {
          kind: 'prompt',
          name: 'Review_Code',
          file: '/a/Review_Code.synapse',
          description: 'Review a change.',
        },
        { kind: 'agent', name: 'Reviewer', file: '/a/Reviewer.synapse', description: null },
      ],
      problems: [],
    })
    expect(await listDefinitions(answered(withPrompt))).toEqual([
      {
        name: 'Review_Code',
        kind: 'prompt',
        path: '/a/Review_Code.synapse',
        description: 'Review a change.',
      },
      { name: 'Reviewer', kind: 'agent', path: '/a/Reviewer.synapse', description: null },
    ])
  })

  it('puts them in the order a person reads a list in, whatever case the names have', async () => {
    const mixed = JSON.stringify({
      format: 'synapse-pipeline-definitions/v1',
      definitions: [
        { kind: 'agent', name: 'Zed', file: '/a/Zed.synapse' },
        { kind: 'agent', name: 'alpha', file: '/a/alpha.synapse' },
        { kind: 'agent', name: 'Beta', file: '/a/Beta.synapse' },
      ],
      problems: [],
    })
    const found = await listDefinitions(answered(mixed))
    expect(found.map((d) => d.name)).toEqual(['alpha', 'Beta', 'Zed'])
  })

  it('has the files that did not load, each with where and why', async () => {
    const found = await loadDefinitions(answered(listing))
    expect(found.problems).toEqual([
      { file: '/a/Broken.synapse', line: 1, column: 22, message: 'expected a name' },
    ])
  })

  it('is listDefinitions without the problems', async () => {
    const found = await listDefinitions(answered(listing))
    expect(found.map((d) => d.name)).toEqual(['Develop', 'Reviewer', 'Strict'])
  })

  it('says what the CLI said when it could not run', async () => {
    await expect(loadDefinitions(answered('', 1, 'error: no home\n'))).rejects.toThrow('no home')
    await expect(loadDefinitions(answered('', 1))).rejects.toThrow('could not run')
  })

  it('refuses an answer that is not JSON or is another format', async () => {
    await expect(loadDefinitions(answered('not json'))).rejects.toThrow('did not answer JSON')
    await expect(
      loadDefinitions(answered(JSON.stringify({ format: 'other/v1', definitions: [] }))),
    ).rejects.toThrow('does not know')
  })
})

describe('listRecordedDefinitions', () => {
  const paths = { definitionDirs: [], recordsDir: '/w/pipelines' }
  const dir = '/w/pipelines/exec-1/definitions/synapse-pipeline'

  it('lists the files a run kept, by name and kind, a recorded Prompt file as a prompt', async () => {
    const transport = fakeTransport({
      paths,
      files: {
        [`${dir}/Dev.synapse`]: 'Pipeline Dev {}',
        [`${dir}/Reviewer.synapse`]: 'Agent Reviewer [Prompt => Review_Code];',
        [`${dir}/Review_Code.synapse`]: '-- Review.\nPrompt Review_Code [Prompt => "Review it."];',
      },
    })
    const kept = await listRecordedDefinitions(transport, 'exec-1')
    expect(kept.definitions.map((d) => [d.name, d.kind])).toEqual([
      ['Dev', 'pipeline'],
      ['Review_Code', 'prompt'],
      ['Reviewer', 'agent'],
    ])
  })

  it('has nothing for a record made before it kept them, or without a work directory', async () => {
    const old = fakeTransport({ paths, files: { '/w/pipelines/exec-1/execution.json': '{}' } })
    expect(await listRecordedDefinitions(old, 'exec-1')).toEqual({ definitions: [] })
    const none = fakeTransport({
      paths: { definitionDirs: [], recordsDir: null },
      files: {},
    })
    expect(await listRecordedDefinitions(none, 'exec-1')).toEqual({ definitions: [] })
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
