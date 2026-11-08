import { copyFileSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { DatabaseSync } from 'node:sqlite'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { claudeHistory, claudeWorkspaces, projectFolderName } from './claude.ts'
import { codexHistory, codexWorkspaces } from './codex.ts'
import { histories, listWorkspaces, type HarnessHistory } from './history.ts'
import { opencodeHistory, opencodeWorkspaces } from './opencode.ts'
import { newestFirst } from './order.ts'

let root: string
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'history-'))
})
afterEach(() => rmSync(root, { recursive: true, force: true }))

function folder(name: string): string {
  const path = join(root, name)
  mkdirSync(path, { recursive: true })
  return path
}

describe('the folders Claude Code is allowed to work in', () => {
  const file = JSON.stringify({
    oauthAccount: { emailAddress: 'someone@example.com' },
    projects: {
      '/a': { hasTrustDialogAccepted: true, lastSessionModified: 1000 },
      '/b': { hasTrustDialogAccepted: true, lastSessionModified: 3000 },
      '/c': { hasTrustDialogAccepted: false, lastSessionModified: 9000 },
      '/d': { hasTrustDialogAccepted: true },
      '/e': { allowedTools: [] },
      '/f': 'not an entry',
    },
  })

  it('are the allowed ones, the most recently used first, those with no time last', () => {
    expect(claudeWorkspaces(file)).toEqual([
      { path: '/b', lastUsed: new Date(3000).toISOString() },
      { path: '/a', lastUsed: new Date(1000).toISOString() },
      { path: '/d', lastUsed: null },
    ])
  })

  it('say nothing of the rest of the file', () => {
    expect(JSON.stringify(claudeWorkspaces(file))).not.toContain('someone@example.com')
  })

  it('are none for a file that is not JSON or has no projects', () => {
    expect(claudeWorkspaces('{ nope')).toEqual([])
    expect(claudeWorkspaces('{"projects": []}')).toEqual([])
    expect(claudeWorkspaces('')).toEqual([])
  })

  it('are read from the folder CLAUDE_CONFIG_DIR names, else the home folder', async () => {
    const other = folder('claude-config')
    writeFileSync(join(other, '.claude.json'), file)
    const named = claudeHistory({ env: { CLAUDE_CONFIG_DIR: other }, home: '/nowhere' })
    expect((await named.workspaces()).map((w) => w.path)).toEqual(['/b', '/a', '/d'])
    const home = folder('home')
    writeFileSync(join(home, '.claude.json'), file)
    expect(await claudeHistory({ env: {}, home }).workspaces()).toHaveLength(3)
    expect(await claudeHistory({ env: {}, home: '/nowhere' }).workspaces()).toEqual([])
  })

  it('name a folder with no time by when its sessions folder last changed', () => {
    expect(projectFolderName('/Users/a/.emacs.d')).toBe('-Users-a--emacs-d')
    expect(projectFolderName('/Users/a/Development/synapse/main')).toBe(
      '-Users-a-Development-synapse-main',
    )
  })

  it('are ordered by the sessions folders for the folders the file has no time for', async () => {
    const home = folder('home')
    const projects = join(home, '.claude', 'projects')
    const older = join(projects, projectFolderName('/older'))
    const newer = join(projects, projectFolderName('/newer'))
    mkdirSync(older, { recursive: true })
    mkdirSync(newer, { recursive: true })
    utimesSync(older, new Date('2026-01-01'), new Date('2026-01-01'))
    utimesSync(newer, new Date('2026-03-01'), new Date('2026-03-01'))
    writeFileSync(
      join(home, '.claude.json'),
      JSON.stringify({
        projects: {
          '/older': { hasTrustDialogAccepted: true },
          '/never': { hasTrustDialogAccepted: true },
          '/newer': { hasTrustDialogAccepted: true },
        },
      }),
    )
    const found = await claudeHistory({ env: {}, home }).workspaces()
    expect(found.map((w) => w.path)).toEqual(['/newer', '/older', '/never'])
    expect(found[0]?.lastUsed).toBe(new Date('2026-03-01').toISOString())
    expect(found[2]?.lastUsed).toBeNull()
  })
})

describe('the folders Codex trusts', () => {
  const toml = [
    'model = "x"',
    '[projects."/a b"]',
    'trust_level = "trusted"',
    '',
    "[projects.'/lit']",
    'trust_level = "trusted"  # approved',
    '[projects."/untrusted"]',
    'trust_level = "untrusted"',
    '[projects."/with \\"quote\\""]',
    'trust_level = "trusted"',
    '[other]',
    'trust_level = "trusted"',
  ].join('\n')

  it('are the trusted tables, the last one in the file first', () => {
    expect(codexWorkspaces(toml)).toEqual([
      { path: '/with "quote"', lastUsed: null },
      { path: '/lit', lastUsed: null },
      { path: '/a b', lastUsed: null },
    ])
  })

  it('are read from CODEX_HOME, else the .codex folder of the home folder', async () => {
    const home = folder('home')
    mkdirSync(join(home, '.codex'))
    writeFileSync(join(home, '.codex', 'config.toml'), toml)
    expect(await codexHistory({ env: {}, home }).workspaces()).toHaveLength(3)
    const other = folder('codex-home')
    writeFileSync(join(other, 'config.toml'), '[projects."/x"]\ntrust_level = "trusted"\n')
    const named = codexHistory({ env: { CODEX_HOME: other }, home })
    expect(await named.workspaces()).toEqual([{ path: '/x', lastUsed: null }])
  })
})

describe('the folders OpenCode has sessions in', () => {
  const COLUMNS =
    '(id text primary key, parent_id text, directory text not null, time_updated integer not null)'

  function database(tables: readonly ('session' | 'session_v2')[], rows = ROWS): string {
    const file = join(root, `opencode-${tables.join('-')}.db`)
    const db = new DatabaseSync(file)
    for (const table of tables) {
      db.exec(`create table ${table} ${COLUMNS}`)
      const add = db.prepare(`insert into ${table} values (?, ?, ?, ?)`)
      for (const row of rows) add.run(...row)
    }
    db.close()
    return file
  }

  const ROWS: readonly [string, string | null, string, number][] = [
    ['1', null, '/old', 1000],
    ['2', null, '/new', 5000],
    ['3', null, '/new', 4000],
    ['4', '1', '/child-only', 9000],
    ['5', null, '', 8000],
  ]

  const EXPECTED = [
    { path: '/new', lastUsed: new Date(5000).toISOString() },
    { path: '/old', lastUsed: new Date(1000).toISOString() },
  ]

  it('are the folders of its own sessions, once each, the most recent first', async () => {
    expect(await opencodeWorkspaces(database(['session_v2']))).toEqual(EXPECTED)
  })

  it('are read from the older table by a version that has no session_v2', async () => {
    expect(await opencodeWorkspaces(database(['session']))).toEqual(EXPECTED)
  })

  it('are read from session_v2 and not from the older table when both are there', async () => {
    const file = join(root, 'both.db')
    const db = new DatabaseSync(file)
    db.exec(`create table session ${COLUMNS}`)
    db.exec(`create table session_v2 ${COLUMNS}`)
    db.prepare('insert into session values (?, ?, ?, ?)').run('1', null, '/stale', 9000)
    db.prepare('insert into session_v2 values (?, ?, ?, ?)').run('1', null, '/current', 1000)
    db.close()
    expect((await opencodeWorkspaces(file)).map((w) => w.path)).toEqual(['/current'])
  })

  it('are none when there is no database', async () => {
    expect(await opencodeWorkspaces(join(root, 'missing.db'))).toEqual([])
  })

  it('are read from XDG_DATA_HOME, else the share folder of the home folder', async () => {
    const data = folder('data')
    mkdirSync(join(data, 'opencode'))
    const source = database(['session_v2'])
    copyFileSync(source, join(data, 'opencode', 'opencode.db'))
    const named = opencodeHistory({ env: { XDG_DATA_HOME: data }, home: '/nowhere' })
    expect(await named.workspaces()).toHaveLength(2)
    const home = folder('home')
    mkdirSync(join(home, '.local', 'share', 'opencode'), { recursive: true })
    copyFileSync(source, join(home, '.local', 'share', 'opencode', 'opencode.db'))
    expect(await opencodeHistory({ env: {}, home }).workspaces()).toHaveLength(2)
  })
})

describe('the order', () => {
  it('puts the newest first and keeps the order of those with no time, after', () => {
    expect(
      newestFirst([
        { path: 'x', lastUsed: null },
        { path: 'a', lastUsed: '2026-01-01T00:00:00.000Z' },
        { path: 'y', lastUsed: null },
        { path: 'b', lastUsed: '2026-02-01T00:00:00.000Z' },
      ]).map((w) => w.path),
    ).toEqual(['b', 'a', 'x', 'y'])
  })
})

describe('the same question of every harness', () => {
  function fake(harness: HarnessHistory['harness'], paths: string[] | Error): HarnessHistory {
    return {
      harness,
      workspaces: () =>
        paths instanceof Error
          ? Promise.reject(paths)
          : Promise.resolve(paths.map((path) => ({ path, lastUsed: null }))),
    }
  }

  it('gives a list for each harness, without the folders that are gone', async () => {
    const here = folder('here')
    const result = await listWorkspaces([
      fake('Claude', [here, join(root, 'deleted')]),
      fake('Codex', []),
      fake('Opencode', [here]),
    ])
    expect(result).toEqual({
      Claude: [{ path: here, lastUsed: null }],
      Codex: [],
      Opencode: [{ path: here, lastUsed: null }],
    })
  })

  it('gives none for a harness that fails, and the others as they are', async () => {
    const here = folder('here')
    const result = await listWorkspaces([
      fake('Claude', new Error('unreadable')),
      fake('Codex', [here]),
      fake('Opencode', []),
    ])
    expect(result.Claude).toEqual([])
    expect(result.Codex).toHaveLength(1)
  })

  it('has an adapter for each harness there is', () => {
    expect(
      histories({ env: {}, home: root })
        .map((h) => h.harness)
        .sort(),
    ).toEqual(['Claude', 'Codex', 'Opencode'])
  })
})
