import { describe, expect, it } from 'vitest'
import type { SessionPlan } from './inject.ts'
import {
  createdPath,
  failureOf,
  NOTE_TOOLS,
  noteCommand,
  notePrompt,
  OPENCODE_PERMISSION,
  pathsOf,
  vaultDirOf,
} from './note-agent.ts'

const plan: SessionPlan = {
  command: 'claude',
  args: ['--add-dir', '/overlay', '--settings', '/settings.json'],
  env: {},
  loaded: true,
  note: '',
}

describe('the prompt for a note', () => {
  it('names the skill of the kind of note and holds the description', () => {
    const note = notePrompt('note', '  Why the cache is keyed by branch  ', 'Claude')
    expect(note).toContain('use the synapse-note skill in bare mode')
    expect(note).toContain('Description:\nWhy the cache is keyed by branch')
    expect(notePrompt('task', 'x', 'Claude')).toContain('synapse-note skill with --task')
    expect(notePrompt('design', 'x', 'Claude')).toContain('synapse-design-note skill')
  })

  it('says nobody can answer, which commands work and how to write, and what to end with', () => {
    const text = notePrompt('note', 'x', 'Claude')
    expect(text).toContain('Nobody can answer questions')
    expect(text).toContain('Only these commands work in this session: synapse, ls, cat')
    expect(text).toContain('one command in each Bash call')
    expect(text).toContain('vault-write <path>` on standard input as a here-document')
    expect(text).toContain('path in the vault')
    expect(text).toContain('FAILED:')
  })

  it('names the commands that work to the harnesses that hold a session to them, and not to Codex', () => {
    expect(notePrompt('note', 'x', 'Opencode')).toContain('Only these commands work')
    const codex = notePrompt('note', 'x', 'Codex')
    expect(codex).not.toContain('Only these commands work')
    expect(codex).toContain('vault-write <path>` on standard input')
  })
})

describe('the headless session for a note', () => {
  it('reads the prompt from standard input, refuses what is not allowed and loads Synapse', () => {
    const command = noteCommand('Claude', plan, 'the prompt', ['/vault'])
    expect(command.stdin).toBe('the prompt')
    expect(command.args).toEqual(
      expect.arrayContaining(['-p', '--permission-mode', 'dontAsk', '--no-session-persistence']),
    )
    expect(command.args.slice(-4)).toEqual([
      '--add-dir',
      '/overlay',
      '--settings',
      '/settings.json',
    ])
    // The tools are one argument, so that no flag can be taken into them.
    const at = command.args.indexOf('--allowedTools')
    expect(command.args[at + 1]).toBe(NOTE_TOOLS)
  })

  it('allows the skills, the Synapse program and the lists the skills keep, and no shell', () => {
    const tools = NOTE_TOOLS.split(',')
    expect(tools).toContain('Skill')
    expect(tools).toContain('Bash(synapse *)')
    expect(tools.some((tool) => tool === 'Bash' || tool === 'Write')).toBe(false)
    expect(tools.filter((tool) => tool.startsWith('Edit('))).toEqual([
      'Edit(~/.config/synapse/**)',
      'Edit(~/.claude/synapse-*.conf)',
    ])
  })

  it('gives Codex the prompt on standard input, its sandbox and the folders it may write in', () => {
    const codexPlan: SessionPlan = { ...plan, command: 'codex', args: [] }
    const command = noteCommand('Codex', codexPlan, 'the prompt', ['/vault', '/cfg'])
    expect(command.stdin).toBe('the prompt')
    expect(command.args.slice(0, 3)).toEqual(['exec', '--ephemeral', '--skip-git-repo-check'])
    expect(command.args).toEqual(expect.arrayContaining(['-s', 'workspace-write']))
    // The sandbox never asks: a request would have nobody to answer it.
    expect(command.args).toContain('approval_policy="never"')
    const added = command.args.flatMap((arg, i) =>
      arg === '--add-dir' ? [command.args[i + 1]] : [],
    )
    expect(added).toEqual(['/vault', '/cfg'])
    expect(command.args.at(-1)).toBe('-')
    expect(command.args).not.toContain('danger-full-access')
  })

  it('gives OpenCode the prompt as its message and holds it to the commands that are allowed', () => {
    const opencodePlan: SessionPlan = { ...plan, command: 'opencode', args: [] }
    const command = noteCommand('Opencode', opencodePlan, 'the prompt', ['/vault'])
    expect(command.stdin).toBe('')
    expect(command.args).toEqual(['run', '--standalone', '--auto', 'the prompt'])
    const given = JSON.parse(command.env.OPENCODE_CONFIG_CONTENT ?? '{}') as {
      permission: typeof OPENCODE_PERMISSION
    }
    expect(given.permission.bash['*']).toBe('deny')
    expect(given.permission.bash['synapse *']).toBe('allow')
    expect(given.permission.bash['cat *']).toBe('allow')
    expect(given.permission.edit['*']).toBe('deny')
    expect(given.permission.webfetch).toBe('deny')
  })
})

describe('the vault named by the settings', () => {
  it('is the value of SYNAPSE_VAULT_DIR, and nothing when there is none or the text is not JSON', () => {
    const listing = JSON.stringify({
      settings: [
        { key: 'OTHER', value: 'x' },
        { key: 'SYNAPSE_VAULT_DIR', value: '/the/vault' },
      ],
    })
    expect(vaultDirOf(listing)).toBe('/the/vault')
    expect(
      vaultDirOf(JSON.stringify({ settings: [{ key: 'SYNAPSE_VAULT_DIR', value: '' }] })),
    ).toBeNull()
    expect(vaultDirOf(JSON.stringify({ settings: [] }))).toBeNull()
    expect(vaultDirOf('not json')).toBeNull()
  })
})

describe('what the session left', () => {
  const before = new Set(['Index.md', 'research/Old.md'])

  it('is the note the agent named when it is a new one', () => {
    const after = [...before, 'research/Cache keys.md', 'inbox/Other.md']
    expect(createdPath('done\nresearch/Cache keys.md\n', before, after)).toBe(
      'research/Cache keys.md',
    )
    expect(createdPath('done\n`research/Cache keys.md`', before, after)).toBe(
      'research/Cache keys.md',
    )
  })

  it('is the first new note when the agent did not name one that is new', () => {
    const after = [...before, 'inbox/Other.md']
    expect(createdPath('all done', before, after)).toBe('inbox/Other.md')
    expect(createdPath('research/Old.md', before, after)).toBe('inbox/Other.md')
  })

  it('is never a graph node, and is nothing when nothing is new', () => {
    expect(createdPath('x', before, [...before, 'synapse/a@main/Node.md'])).toBeNull()
    expect(createdPath('x', before, [...before])).toBeNull()
  })

  it('says why when the agent gave up, and only then', () => {
    expect(failureOf('thinking\nFAILED: no project prefix could be found\n')).toBe(
      'no project prefix could be found',
    )
    expect(failureOf('research/Cache keys.md')).toBeNull()
  })

  it('reads a listing as one path to a line', () => {
    expect(pathsOf('Index.md\n\nresearch/A.md\n')).toEqual(['Index.md', 'research/A.md'])
  })
})
