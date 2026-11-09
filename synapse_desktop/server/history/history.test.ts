import { copyFileSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { DatabaseSync } from 'node:sqlite'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { claudeHistory, claudeSessionHead, claudeWorkspaces, projectFolderName } from './claude.ts'
import { codexHistory, codexSessionHead, codexWorkspaces } from './codex.ts'
import { histories, listSessions, listWorkspaces, type HarnessHistory } from './history.ts'
import { opencodeHistory, opencodeSessions, opencodeWorkspaces } from './opencode.ts'
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
      sessions: () => Promise.resolve([]),
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

const line = (value: unknown) => JSON.stringify(value) + '\n'

describe('what a Claude session file says of its session', () => {
  it('is its folder and its title, the last the harness gave it', () => {
    const text =
      line({ type: 'file-history-snapshot' }) +
      line({ type: 'user', cwd: '/work/one', message: { content: 'hello' } }) +
      line({ type: 'ai-title', aiTitle: 'First title' }) +
      line({ type: 'last-prompt', lastPrompt: 'the last prompt' }) +
      line({ type: 'ai-title', aiTitle: 'Better title' }) +
      line({ type: 'user', cwd: '/work/two' })
    expect(claudeSessionHead(text)).toEqual({ cwd: '/work/one', title: 'Better title' })
  })

  it('has the last prompt as its title when it has no title', () => {
    const text = line({ cwd: '/w' }) + line({ type: 'last-prompt', lastPrompt: 'fix\nthe   bug' })
    expect(claudeSessionHead(text)).toEqual({ cwd: '/w', title: 'fix the bug' })
  })

  it('does not read a line that is long, and ignores a line cut off at the end', () => {
    const long = line({ type: 'user', cwd: '/in/a/long/line', blob: 'x'.repeat(300_000) })
    const cut = '{"type":"ai-title","aiTitle":"Cut of'
    expect(claudeSessionHead(long + line({ cwd: '/short' }) + cut)).toEqual({
      cwd: '/short',
      title: null,
    })
  })

  it('has no folder when the file does not say', () => {
    expect(claudeSessionHead('not json\n')).toEqual({ cwd: null, title: null })
  })
})

describe('what a Codex rollout file says of its session', () => {
  const meta = line({ type: 'session_meta', payload: { id: 'abc', cwd: '/work' } })
  const context = line({
    type: 'response_item',
    payload: {
      type: 'message',
      role: 'user',
      content: [{ type: 'input_text', text: '<environment_context>\n  <cwd>/work</cwd>' }],
    },
  })
  const prompt = (text: string) =>
    line({
      type: 'response_item',
      payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text }] },
    })

  it('is its id, its folder and the first prompt that is not context', () => {
    expect(codexSessionHead(meta + context + prompt('check the design') + prompt('later'))).toEqual(
      {
        id: 'abc',
        cwd: '/work',
        title: 'check the design',
      },
    )
  })

  it('has no title before a prompt, and no id without a session_meta', () => {
    expect(codexSessionHead(meta + context)).toEqual({ id: 'abc', cwd: '/work', title: null })
    expect(codexSessionHead(prompt('hi'))).toEqual({ id: null, cwd: null, title: 'hi' })
  })

  it('does not take a message of the assistant for a prompt', () => {
    const reply = line({
      type: 'response_item',
      payload: { type: 'message', role: 'assistant', content: [{ text: 'Sure' }] },
    })
    expect(codexSessionHead(meta + reply).title).toBeNull()
  })
})

describe('the sessions each harness has kept', () => {
  it('are the newest files of Claude Code, by the folder and title they say', async () => {
    const home = folder('home')
    const projects = join(home, '.claude', 'projects', '-work-one')
    mkdirSync(projects, { recursive: true })
    writeFileSync(
      join(projects, 'aaa-111.jsonl'),
      line({ type: 'user', cwd: '/work/one' }) + line({ type: 'ai-title', aiTitle: 'Old one' }),
    )
    writeFileSync(
      join(projects, 'bbb-222.jsonl'),
      line({ type: 'user', cwd: '/work/one' }) + line({ type: 'ai-title', aiTitle: 'New one' }),
    )
    writeFileSync(join(projects, 'empty.jsonl'), '')
    writeFileSync(join(projects, 'notes.txt'), 'x')
    utimesSync(join(projects, 'aaa-111.jsonl'), new Date('2026-01-01'), new Date('2026-01-01'))
    utimesSync(join(projects, 'bbb-222.jsonl'), new Date('2026-02-01'), new Date('2026-02-01'))
    const found = await claudeHistory({ env: {}, home }).sessions()
    expect(found).toEqual([
      {
        id: 'bbb-222',
        path: '/work/one',
        title: 'New one',
        lastUsed: new Date('2026-02-01').toISOString(),
      },
      {
        id: 'aaa-111',
        path: '/work/one',
        title: 'Old one',
        lastUsed: new Date('2026-01-01').toISOString(),
      },
    ])
  })

  it('are the newest rollout files of Codex, the newest day first', async () => {
    const home = folder('home')
    const day = (d: string) => {
      const path = join(home, '.codex', 'sessions', ...d.split('-'))
      mkdirSync(path, { recursive: true })
      return path
    }
    const rollout = (id: string, cwd: string, text: string) =>
      line({ type: 'session_meta', payload: { id, cwd } }) +
      line({
        type: 'response_item',
        payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text }] },
      })
    writeFileSync(
      join(day('2026-03-01'), 'rollout-2026-03-01T10-00-00-old.jsonl'),
      rollout('old', '/a', 'older'),
    )
    writeFileSync(
      join(day('2026-03-02'), 'rollout-2026-03-02T09-00-00-new.jsonl'),
      rollout('new', '/b', 'newer'),
    )
    writeFileSync(join(day('2026-03-02'), 'other.jsonl'), rollout('x', '/c', 'not a rollout'))
    // Last used is when the file last changed.
    utimesSync(
      join(day('2026-03-01'), 'rollout-2026-03-01T10-00-00-old.jsonl'),
      new Date('2026-03-01'),
      new Date('2026-03-01'),
    )
    utimesSync(
      join(day('2026-03-02'), 'rollout-2026-03-02T09-00-00-new.jsonl'),
      new Date('2026-03-02'),
      new Date('2026-03-02'),
    )
    const found = await codexHistory({ env: {}, home }).sessions()
    expect(found.map((s) => [s.id, s.path, s.title])).toEqual([
      ['new', '/b', 'newer'],
      ['old', '/a', 'older'],
    ])
  })

  it('are the newest top-level sessions of OpenCode, with their titles', async () => {
    const file = join(root, 'sessions.db')
    const db = new DatabaseSync(file)
    db.exec(
      'create table session_v2 (id text primary key, parent_id text, directory text not null, title text, time_updated integer not null)',
    )
    const add = db.prepare('insert into session_v2 values (?, ?, ?, ?, ?)')
    add.run('ses_1', null, '/a', 'Older', 1000)
    add.run('ses_2', null, '/b', null, 5000)
    add.run('ses_3', 'ses_1', '/a', 'A child', 9000)
    add.run('ses_4', null, '', 'No folder', 8000)
    db.close()
    expect(await opencodeSessions(file)).toEqual([
      { id: 'ses_2', path: '/b', title: null, lastUsed: new Date(5000).toISOString() },
      { id: 'ses_1', path: '/a', title: 'Older', lastUsed: new Date(1000).toISOString() },
    ])
    expect(await opencodeSessions(join(root, 'missing.db'))).toEqual([])
  })

  it('are listed for every harness, without those whose folder is gone, at most so many', async () => {
    const here = folder('here')
    const many = Array.from({ length: 30 }, (_, i) => ({
      id: `s${i}`,
      path: here,
      title: null,
      lastUsed: null,
    }))
    const history = (
      harness: HarnessHistory['harness'],
      sessions: HarnessHistory['sessions'],
    ): HarnessHistory => ({ harness, workspaces: () => Promise.resolve([]), sessions })
    const result = await listSessions([
      history('Claude', () =>
        Promise.resolve([
          { id: 'a', path: join(root, 'gone'), title: null, lastUsed: null },
          ...many,
        ]),
      ),
      history('Codex', () => Promise.reject(new Error('unreadable'))),
      history('Opencode', () => Promise.resolve([])),
    ])
    expect(result.Claude).toHaveLength(20)
    expect(result.Claude.every((s) => s.path === here)).toBe(true)
    expect(result.Codex).toEqual([])
    expect(result.Opencode).toEqual([])
  })
})
