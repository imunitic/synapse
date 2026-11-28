import { describe, expect, it } from 'vitest'
import type { SessionPlan } from './inject.ts'
import {
  createdPath,
  failureOf,
  folderSentence,
  lineSplitter,
  NOTE_TOOLS,
  noteCommand,
  notePrompt,
  OPENCODE_PERMISSION,
  OPENCODE_READ_PERMISSION,
  pathsOf,
  READ_TOOLS,
  reasonOf,
  sessionPrompt,
  streamResult,
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
    expect(text).toContain('to note.md in the current folder')
    expect(text).toContain('`synapse vault-write <path> < note.md`')
    expect(text).toContain('`synapse vault-search < query.json`')
    expect(text).toContain('never as a here-document and never through cat, echo or <<<')
    expect(text).toContain('add the folder to Index.md')
    expect(text).toContain('path in the vault')
    expect(text).toContain('FAILED:')
  })

  it('never lets a session add a project, whichever harness writes the note', () => {
    for (const harness of ['Claude', 'Codex', 'Opencode'] as const) {
      const text = notePrompt('task', 'x', harness, [{ name: 'a', prefix: 'b' }])
      expect(text).toContain('Never add a project')
      expect(text).toContain('so that the person can add one on the page')
    }
  })

  it('lists the projects there are for a task or design note, to match the description to', () => {
    const projects = [
      { name: 'synapse', prefix: 'sb' },
      { name: 'eon', prefix: 'ecs' },
    ]
    const task = notePrompt('task', 'x', 'Claude', projects)
    expect(task).toContain('as name=prefix: synapse=sb, eon=ecs')
    expect(task).toContain('is in tasks/NAME/ and has the project PREFIX')
    expect(task).toContain('matching loosely')
    expect(notePrompt('design', 'x', 'Codex', projects)).toContain('designs/NAME/')
    expect(notePrompt('task', 'x', 'Claude', [])).toContain('There are none.')
  })

  it('names the project that was chosen, with its folder and prefix, and asks for no other', () => {
    const chosen = { name: 'synapse', prefix: 'sb' }
    const text = notePrompt(
      'design',
      'x',
      'Claude',
      [chosen, { name: 'eon', prefix: 'ecs' }],
      chosen,
    )
    expect(text).toContain('The project of this note is synapse, with the prefix sb')
    expect(text).toContain('in designs/synapse/ and its project is sb')
    expect(text).not.toContain('eon=ecs')
    expect(text).not.toContain('Never add a project')
  })

  it('says nothing of projects to a plain note', () => {
    const text = notePrompt('note', 'x', 'Claude', [{ name: 'synapse', prefix: 'sb' }])
    expect(text).not.toContain('project')
  })

  it('asks every harness for the note skill of the kind of note by name', () => {
    for (const harness of ['Claude', 'Codex', 'Opencode'] as const) {
      expect(notePrompt('task', 'x', harness)).toContain('use the synapse-note skill with --task')
      expect(notePrompt('design', 'x', harness)).toContain('use the synapse-design-note skill')
      expect(notePrompt('note', 'x', harness)).toContain('use the synapse-note skill in bare mode')
      expect(notePrompt('task', 'x', harness)).not.toContain('Read the file of')
    }
  })

  it('names the commands that work to the harnesses that hold a session to them, and not to Codex', () => {
    expect(notePrompt('note', 'x', 'Opencode')).toContain('Only these commands work')
    const codex = notePrompt('note', 'x', 'Codex')
    expect(codex).not.toContain('Only these commands work')
    expect(codex).toContain('on standard input as a here-document')
  })

  it('has Claude Code write a new note to a file, since a command with the whole note is refused, and the others give it on standard input', () => {
    expect(notePrompt('note', 'x', 'Claude')).not.toContain(
      "Give a note's text to `synapse vault-write <path>`",
    )
    for (const harness of ['Opencode', 'Codex'] as const) {
      const text = notePrompt('note', 'x', harness)
      expect(text).toContain("Give a note's text to `synapse vault-write <path>`")
      expect(text).not.toContain('note.md')
    }
  })
})

describe('the prompt a session is given', () => {
  it('says where its folder is first, and ends with the prompt, so the description stays last', () => {
    const prompt = notePrompt('note', 'Why the cache is keyed by branch', 'Claude')
    const given = sessionPrompt(prompt, '/tmp/synapse-note-abc')
    expect(given.startsWith(folderSentence('/tmp/synapse-note-abc'))).toBe(true)
    expect(given.endsWith('Description:\nWhy the cache is keyed by branch')).toBe(true)
    expect(given).toContain('/tmp/synapse-note-abc')
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

  it('may also read the Synapse package folder when it is loaded for the session', () => {
    const loaded: SessionPlan = { ...plan, env: { SYNAPSE_CONTENT_ROOT: '/pkg/synapse' } }
    const command = noteCommand('Claude', loaded, 'p', [])
    const at = command.args.indexOf('--allowedTools')
    expect(command.args[at + 1]).toBe(`${NOTE_TOOLS},Read(/pkg/synapse/**)`)
  })

  it('allows the skills, the Synapse program and reading the lists the skills keep, and no shell', () => {
    const tools = NOTE_TOOLS.split(',')
    expect(tools).toContain('Skill')
    expect(tools).toContain('Bash(synapse *)')
    expect(tools).toContain('Read(~/.config/synapse/**)')
    expect(tools.some((tool) => tool === 'Bash' || tool === 'Write')).toBe(false)
  })

  it('lets a session add to the tag vocabulary and to no other list, the projects list included, and edit the files of its own folder', () => {
    const edits = NOTE_TOOLS.split(',').filter((tool) => tool.startsWith('Edit('))
    expect(edits).toEqual([
      'Edit(~/.config/synapse/synapse-tag-vocabulary.conf)',
      'Edit(~/.claude/synapse-tag-vocabulary.conf)',
      // Relative to the session's folder, which is empty and its own.
      'Edit(./**)',
    ])
    expect(edits.some((edit) => edit.includes('projects'))).toBe(false)
    // The only pattern that reaches files is the one inside the session's own folder.
    expect(edits.filter((edit) => edit.includes('**'))).toEqual(['Edit(./**)'])
  })

  it('holds OpenCode to the same: only the tag vocabulary may be edited', () => {
    const allowed = Object.entries(OPENCODE_PERMISSION.edit)
      .filter(([, action]) => action === 'allow')
      .map(([pattern]) => pattern)
    expect(allowed).toEqual([
      '~/.config/synapse/synapse-tag-vocabulary.conf',
      '~/.claude/synapse-tag-vocabulary.conf',
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

  it('gives as the reason what the agent said, whatever the harness printed besides', () => {
    // Codex prints its banner, the prompt and its hooks on standard error, and the reply on
    // standard output.
    const banner =
      '\u001b[1mworkdir:\u001b[0m /w\nuser\nChange one note...\nhello\ntokens used\n8,015\n'
    expect(reasonOf('hello\n', banner)).toBe('hello')
    expect(reasonOf('thinking\nFAILED: no such note\n', banner)).toBe('no such note')
  })

  it('falls back to the end of standard error, without colours, when nothing was said', () => {
    expect(reasonOf('', '\u001b[31mError:\u001b[0m the model refused\n')).toBe(
      'Error: the model refused',
    )
    expect(reasonOf('  \n', '')).toBe('')
  })

  it('keeps only the end of a long reply', () => {
    const long = 'x'.repeat(1000) + 'THE END'
    const reason = reasonOf(long, '')
    expect(reason).toHaveLength(300)
    expect(reason.endsWith('THE END')).toBe(true)
  })

  it('reads a listing as one path to a line', () => {
    expect(pathsOf('Index.md\n\nresearch/A.md\n')).toEqual(['Index.md', 'research/A.md'])
  })
})

describe('a read session', () => {
  it('a read session of Claude may only read and search the vault', () => {
    const loaded: SessionPlan = { ...plan, env: { SYNAPSE_CONTENT_ROOT: '/pkg/synapse' } }
    const command = noteCommand('Claude', loaded, 'p', [], undefined, undefined, false, 'read')
    const at = command.args.indexOf('--allowedTools')
    expect(command.args[at + 1]).toBe(READ_TOOLS)
    expect(READ_TOOLS.split(',')).toEqual([
      'Bash(synapse vault-search-text *)',
      'Bash(synapse vault-list)',
      'Bash(synapse vault-list *)',
      'Bash(synapse vault-read *)',
    ])
    expect(command.args.join(' ')).not.toMatch(/Skill|Read\(|Edit\(/)
    expect(command.args).toEqual(expect.arrayContaining(['--permission-mode', 'dontAsk']))
  })

  it('a read session of Codex is read-only with no added folders', () => {
    const codexPlan: SessionPlan = { ...plan, command: 'codex', args: [] }
    const command = noteCommand(
      'Codex',
      codexPlan,
      'p',
      ['/vault'],
      undefined,
      undefined,
      false,
      'read',
    )
    expect(command.args).toEqual(expect.arrayContaining(['-s', 'read-only']))
    expect(command.args).not.toContain('workspace-write')
    expect(command.args).not.toContain('--add-dir')
  })

  it('a read session of OpenCode denies edits and all other commands', () => {
    const opencodePlan: SessionPlan = { ...plan, command: 'opencode', args: [] }
    const command = noteCommand(
      'Opencode',
      opencodePlan,
      'p',
      [],
      undefined,
      undefined,
      false,
      'read',
    )
    const given = JSON.parse(command.env.OPENCODE_CONFIG_CONTENT ?? '{}') as {
      permission: typeof OPENCODE_READ_PERMISSION
    }
    expect(given.permission).toEqual(OPENCODE_READ_PERMISSION)
    expect(given.permission.bash).toEqual({
      '*': 'deny',
      'synapse vault-search-text *': 'allow',
      'synapse vault-list*': 'allow',
      'synapse vault-read *': 'allow',
    })
    expect(given.permission.edit).toEqual({ '*': 'deny' })
    expect(given.permission.webfetch).toBe('deny')
  })

  it('leaves the write session args unchanged', () => {
    for (const harness of ['Claude', 'Codex', 'Opencode'] as const) {
      expect(noteCommand(harness, plan, 'p', ['/v'], 'm', undefined, false, 'write')).toEqual(
        noteCommand(harness, plan, 'p', ['/v'], 'm'),
      )
    }
  })
})

describe('the model of a note session', () => {
  it('is given to each harness by its own flag, before what ends the arguments', () => {
    const claude = noteCommand('Claude', plan, 'p', ['/v'], 'sonnet').args
    expect(claude.slice(-2)).toEqual(['--model', 'sonnet'])
    const codex = noteCommand('Codex', plan, 'p', ['/v'], 'gpt-x').args
    expect(codex.slice(-3)).toEqual(['-m', 'gpt-x', '-'])
    const opencode = noteCommand('Opencode', plan, 'the prompt', ['/v'], 'prov/model').args
    expect(opencode.slice(-3)).toEqual(['-m', 'prov/model', 'the prompt'])
  })

  it('is left to the harness when there is none', () => {
    for (const harness of ['Claude', 'Codex', 'Opencode'] as const) {
      const args = noteCommand(harness, plan, 'p', ['/v']).args
      expect(args).not.toContain('--model')
      expect(args).not.toContain('-m')
    }
  })
})

describe('the effort of a note session', () => {
  it('Claude is given --effort', () => {
    const args = noteCommand('Claude', plan, 'p', ['/v'], 'sonnet', 'high').args
    expect(args.slice(-4)).toEqual(['--model', 'sonnet', '--effort', 'high'])
  })

  it('Codex is given model_reasoning_effort', () => {
    const args = noteCommand('Codex', plan, 'p', ['/v'], 'gpt-x', 'xhigh').args
    expect(args.slice(-5)).toEqual(['-m', 'gpt-x', '-c', 'model_reasoning_effort="xhigh"', '-'])
  })

  it('OpenCode is given model#variant', () => {
    const args = noteCommand('Opencode', plan, 'the prompt', ['/v'], 'prov/model', 'high').args
    expect(args.slice(-3)).toEqual(['-m', 'prov/model#high', 'the prompt'])
  })

  it('no effort adds no argument', () => {
    for (const harness of ['Claude', 'Codex', 'Opencode'] as const) {
      expect(noteCommand(harness, plan, 'p', ['/v'], 'm', undefined)).toEqual(
        noteCommand(harness, plan, 'p', ['/v'], 'm'),
      )
      const args = noteCommand(harness, plan, 'p', ['/v'], 'm').args
      expect(args).not.toContain('--effort')
      expect(args.join(' ')).not.toContain('model_reasoning_effort')
      expect(args.join(' ')).not.toContain('#')
    }
  })
})

describe('the stream of a Claude note session', () => {
  it('prints stream-json events and keeps every other flag', () => {
    const plain = noteCommand('Claude', plan, 'p', ['/v']).args
    const streamed = noteCommand('Claude', plan, 'p', ['/v'], undefined, undefined, true).args
    const at = streamed.indexOf('--output-format')
    expect(streamed.slice(at, at + 3)).toEqual(['--output-format', 'stream-json', '--verbose'])
    expect(streamed).not.toContain('text')
    expect(streamed).toContain('--no-session-persistence')
    const without = (args: string[]) =>
      args.filter((arg) => !['text', 'stream-json', '--verbose'].includes(arg))
    expect(without(streamed)).toEqual(without(plain))
    expect(plain).toContain('text')
    expect(plain).not.toContain('--verbose')
  })

  it('leaves the Codex and OpenCode commands as they are', () => {
    for (const harness of ['Codex', 'Opencode'] as const) {
      expect(noteCommand(harness, plan, 'p', ['/v'], undefined, undefined, true)).toEqual(
        noteCommand(harness, plan, 'p', ['/v']),
      )
    }
  })
})

describe('the result of a stream', () => {
  const event = (value: object) => JSON.stringify(value)

  it('is the text of the last result event', () => {
    const transcript = [
      event({ type: 'system', subtype: 'init' }),
      event({ type: 'assistant', message: { content: [] } }),
      event({ type: 'result', result: 'first' }),
      event({ type: 'result', result: 'EDITED' }),
    ].join('\n')
    expect(streamResult(transcript)).toBe('EDITED')
  })

  it('is empty without a result event', () => {
    expect(streamResult(event({ type: 'assistant' }))).toBe('')
    expect(streamResult('')).toBe('')
  })

  it('keeps the reason of a failed run readable', () => {
    const transcript = `${event({ type: 'assistant' })}\n${event({ type: 'result', result: 'tried\nFAILED: no such note' })}\n`
    expect(failureOf(streamResult(transcript))).toBe('no such note')
  })

  it('skips lines that are not JSON', () => {
    expect(streamResult(`oops\n${event({ type: 'result', result: 'ok' })}\n{broken`)).toBe('ok')
    expect(streamResult('plain\ntext')).toBe('')
  })
})

describe('the line splitter', () => {
  it('hands over whole lines, also when a chunk splits one', () => {
    const lines: string[] = []
    const splitter = lineSplitter((line) => lines.push(line))
    splitter.write('one\ntw')
    expect(lines).toEqual(['one'])
    splitter.write('o\n\n  \nthree\n')
    expect(lines).toEqual(['one', 'two', 'three'])
    splitter.end()
    expect(lines).toEqual(['one', 'two', 'three'])
  })

  it('hands over a last line with no newline on end', () => {
    const lines: string[] = []
    const splitter = lineSplitter((line) => lines.push(line))
    splitter.write('a\nlast')
    expect(lines).toEqual(['a'])
    splitter.end()
    expect(lines).toEqual(['a', 'last'])
  })
})
