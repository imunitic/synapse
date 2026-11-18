import { describe, expect, it } from 'vitest'
import type { CliResult, Transport } from '../../shared/transport.ts'
import {
  filterPaths,
  searchPaths,
  findSymbol,
  listCoveredPaths,
  listGraphs,
  listNodes,
  listUnassigned,
  nodeNotePath,
  ownersOf,
  parseGraphs,
  parseSymbolHits,
  splitPlace,
} from './graph-search.ts'

function answering(answer: (args: string[]) => CliResult): {
  transport: Transport
  seen: string[][]
} {
  const seen: string[][] = []
  const transport = {
    cli: (_binary: string, args: string[]) => {
      seen.push(args)
      return Promise.resolve(answer(args))
    },
  } as unknown as Transport
  return { transport, seen }
}

const ok = (stdout: string): CliResult => ({ code: 0, stdout, stderr: '' })

describe('the graphs a machine has', () => {
  it('are read from work-dir --list, with what each has', async () => {
    expect(parseGraphs('a@main\tindex,refs,tags\nb@dev\trefs\n')).toEqual([
      { namespace: 'a@main', hasIndex: true, hasRefs: true, hasTags: true },
      { namespace: 'b@dev', hasIndex: false, hasRefs: true, hasTags: false },
    ])
    const { transport, seen } = answering(() => ok('a@main\tindex\n'))
    expect(await listGraphs(transport)).toHaveLength(1)
    expect(seen[0]).toEqual(['work-dir', '--list'])
    expect(parseGraphs('')).toEqual([])
  })
})

describe('the hits of a symbol', () => {
  it('split a place into a path and a line, and keep a path that has no line', () => {
    expect(splitPlace('src/a.adb:24')).toEqual({ path: 'src/a.adb', line: 24 })
    expect(splitPlace('C:/x/a.adb:7')).toEqual({ path: 'C:/x/a.adb', line: 7 })
    expect(splitPlace('src/a.adb')).toEqual({ path: 'src/a.adb', line: null })
    expect(splitPlace('src/a.adb:x')).toEqual({ path: 'src/a.adb:x', line: null })
  })

  it('are calls with their expression, or with --all definitions and references of a kind', () => {
    expect(parseSymbolHits('src/a.adb:24\tFoo (1, 2);\nsrc/b.adb:3\tBar\tbaz\n', false)).toEqual([
      { role: 'call', kind: null, path: 'src/a.adb', line: 24, expression: 'Foo (1, 2);' },
      { role: 'call', kind: null, path: 'src/b.adb', line: 3, expression: 'Bar\tbaz' },
    ])
    expect(
      parseSymbolHits(
        'def\tfunction\tsrc/a.ads:16\tfunction Work_Dir\nref\tcall\tsrc/b.adb:9\tWork_Dir (X)\nodd\tx\n',
        true,
      ),
    ).toEqual([
      {
        role: 'def',
        kind: 'function',
        path: 'src/a.ads',
        line: 16,
        expression: 'function Work_Dir',
      },
      { role: 'ref', kind: 'call', path: 'src/b.adb', line: 9, expression: 'Work_Dir (X)' },
    ])
  })

  it('are found with callers, naming the namespace', async () => {
    const { transport, seen } = answering(() => ok('src/a.adb:1\tx\n'))
    expect(await findSymbol(transport, 'synapse@main', 'Resolve', false)).toHaveLength(1)
    expect(await findSymbol(transport, 'synapse@main', 'Resolve', true)).toHaveLength(0)
    expect(seen).toEqual([
      ['callers', 'Resolve', '--namespace', 'synapse@main'],
      ['callers', 'Resolve', '--all', '--namespace', 'synapse@main'],
    ])
  })
})

describe('the index of a namespace', () => {
  it('gives the nodes, the covered paths, the unassigned ones and the owners of a path', async () => {
    const { transport, seen } = answering((args) =>
      ok(args[1] === 'lookup' ? 'Node A.md\n' : 'one\ntwo\n'),
    )
    expect(await listNodes(transport, 'a@b')).toEqual(['one', 'two'])
    expect(await listCoveredPaths(transport, 'a@b')).toEqual(['one', 'two'])
    expect(await listUnassigned(transport, 'a@b')).toEqual(['one', 'two'])
    expect(await ownersOf(transport, 'a@b', 'src/x.adb')).toEqual(['Node A.md'])
    expect(seen).toEqual([
      ['index', 'nodes', '--namespace', 'a@b'],
      ['index', 'paths', '--namespace', 'a@b'],
      ['index', 'unassigned', '--namespace', 'a@b'],
      ['index', 'lookup', 'src/x.adb', '--namespace', 'a@b'],
    ])
  })

  it('fails with the reason when the program does', async () => {
    const { transport } = answering(() => ({
      code: 1,
      stdout: '',
      stderr: 'synapse-index: no index\n',
    }))
    await expect(listNodes(transport, 'a@b')).rejects.toThrow('no index')
  })

  it('names a node by its note in the vault', () => {
    expect(nodeNotePath('a@b', 'CLI entry point & dispatch.md')).toBe(
      'synapse/a@b/CLI entry point & dispatch.md',
    )
    expect(nodeNotePath('a@b', 'No extension')).toBe('synapse/a@b/No extension.md')
  })
})

describe('the paths that match words', () => {
  const paths = [
    'src/commands/config.adb',
    'docs/config-notes.md',
    'src/config/other.adb',
    'README.md',
    'src/Commands/Config_Tests.adb',
  ]

  it('hold every word in any case, those with the words in the file name first, then shorter', () => {
    expect(filterPaths(paths, 'config', 10)).toEqual([
      'docs/config-notes.md',
      'src/commands/config.adb',
      'src/Commands/Config_Tests.adb',
      'src/config/other.adb',
    ])
    expect(filterPaths(paths, 'COMMANDS adb', 10)).toEqual([
      'src/commands/config.adb',
      'src/Commands/Config_Tests.adb',
    ])
  })

  it('are none for no words, and no more than the limit', () => {
    expect(filterPaths(paths, '   ', 10)).toEqual([])
    expect(filterPaths(paths, 'adb', 1)).toHaveLength(1)
    expect(filterPaths(paths, 'zzz', 10)).toEqual([])
  })
})

describe('searching the paths', () => {
  const paths = ['src/a.adb', 'src/b.adb', 'src/c.ads', 'docs/a.md']

  it('gives how many paths hold the words as well as the ones it returns', () => {
    expect(searchPaths(paths, 'adb', 1)).toEqual({ paths: ['src/a.adb'], total: 2 })
    expect(searchPaths(paths, 'src', 10).total).toBe(3)
  })

  it('finds nothing for words that are not there or no words', () => {
    expect(searchPaths(paths, 'zzz', 10)).toEqual({ paths: [], total: 0 })
    expect(searchPaths(paths, '  ', 10)).toEqual({ paths: [], total: 0 })
  })
})
