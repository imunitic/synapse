import { describe, expect, it } from 'vitest'
import { defaultConfig } from '../shared/calls.ts'
import type { CliResult } from '../shared/transport.ts'
import type { CliRun } from './cli.ts'
import {
  editNote,
  EditRefused,
  notePathProblem,
  restoreNote,
  touchedElsewhere,
} from './note-edit.ts'
import { editPrompt } from './note-agent.ts'

// A vault of notes in memory, answering the programs the edit asks of it.
function vault(initial: Record<string, string>) {
  const files = new Map(Object.entries(initial))
  const writes: string[] = []
  const run = (r: CliRun): Promise<CliResult> => {
    const ok = (stdout: string): Promise<CliResult> =>
      Promise.resolve({ code: 0, stdout, stderr: '' })
    switch (r.args[0]) {
      case 'vault-read': {
        const text = files.get(r.args[1] ?? '')
        return text === undefined
          ? Promise.resolve({ code: 1, stdout: '', stderr: 'no such note' })
          : ok(text)
      }
      case 'vault-list':
        return ok([...files.keys()].join('\n') + '\n')
      case 'vault-search':
        return ok(
          [...files]
            .flatMap(([path, text]) => {
              const stamp = /^updated: (.*)$/m.exec(text)?.[1]
              return stamp === undefined ? [] : [`${path}\t${stamp}`]
            })
            .join('\n') + '\n',
        )
      case 'vault-write':
        writes.push(r.args[1] ?? '')
        files.set(r.args[1] ?? '', r.stdin ?? '')
        return ok('')
      default:
        return Promise.reject(new Error(`not expected: ${r.args.join(' ')}`))
    }
  }
  return { files, writes, run }
}

const note = (updated: string, body = 'text') => `---\nupdated: ${updated}\n---\n${body}\n`

const answer = (stdout: string): CliResult => ({ code: 0, stdout, stderr: '' })

describe('a note that may be changed', () => {
  it('is named by its path in the vault, is a .md file and is not a node of a code graph', () => {
    expect(notePathProblem('research/A note.md')).toBeNull()
    expect(notePathProblem('Index.md')).toBeNull()
    expect(notePathProblem('synapse-notes/A.md')).toBeNull()
    expect(notePathProblem('')).toMatch(/no such note/)
    expect(notePathProblem('/etc/passwd.md')).toMatch(/path in the vault/)
    expect(notePathProblem('C:/x.md')).toMatch(/path in the vault/)
    expect(notePathProblem('a/../../b.md')).toMatch(/path in the vault/)
    expect(notePathProblem('research/data.json')).toMatch(/\.md file/)
    expect(notePathProblem('synapse/widget@main/Rendering.md')).toMatch(/code graph/)
  })
})

describe('the other notes that moved', () => {
  const seen = (stamps: Record<string, string>, paths: string[]) => ({
    stamps: new Map(Object.entries(stamps)),
    paths: new Set(paths),
  })

  it('are those whose date changed, that are new and that are gone, and never the note itself', () => {
    const before = seen({ 'a.md': '1', 'b.md': '1', 'c.md': '1' }, [
      'a.md',
      'b.md',
      'c.md',
      'old.md',
    ])
    const after = seen({ 'a.md': '2', 'b.md': '1', 'd.md': '9' }, [
      'a.md',
      'b.md',
      'd.md',
      'new.md',
    ])
    expect(touchedElsewhere(before, after, 'a.md')).toEqual(['c.md', 'd.md', 'new.md', 'old.md'])
  })

  it('are none when only the note itself moved', () => {
    const before = seen({ 'a.md': '1', 'b.md': '1' }, ['a.md', 'b.md'])
    const after = seen({ 'a.md': '2', 'b.md': '1' }, ['a.md', 'b.md'])
    expect(touchedElsewhere(before, after, 'a.md')).toEqual([])
  })
})

describe('having an agent change a note', () => {
  it('gives back the note as it was and as it is, and the prompt names the note and the rules', async () => {
    const fake = vault({ 'a.md': note('1', 'old'), 'b.md': note('1') })
    const prompts: string[] = []
    const edit = await editNote(
      {
        run: fake.run,
        config: defaultConfig,
        harness: 'Claude',
        session: (prompt) => {
          prompts.push(prompt)
          fake.files.set('a.md', note('2', 'new'))
          return Promise.resolve(answer('done\nEDITED\n'))
        },
      },
      'a.md',
      'Say new instead of old',
    )
    expect(edit).toEqual({ before: note('1', 'old'), after: note('2', 'new'), touched: [] })
    expect(prompts[0]).toContain('The note is `a.md`')
    expect(prompts[0]).toContain('Say new instead of old')
    expect(prompts[0]).toContain('change no other note')
  })

  it('names the other notes the agent moved', async () => {
    const fake = vault({ 'a.md': note('1'), 'b.md': note('1') })
    const edit = await editNote(
      {
        run: fake.run,
        config: defaultConfig,
        harness: 'Claude',
        session: () => {
          fake.files.set('a.md', note('2', 'changed'))
          fake.files.set('b.md', note('2', 'also changed'))
          fake.files.set('new.md', note('2'))
          return Promise.resolve(answer('EDITED'))
        },
      },
      'a.md',
      'x',
    )
    expect(edit.touched).toEqual(['b.md', 'new.md'])
  })

  it('says why when the note was not changed, with what the agent said', async () => {
    const fake = vault({ 'a.md': note('1') })
    const refused = await editNote(
      {
        run: fake.run,
        config: defaultConfig,
        harness: 'Claude',
        session: () => Promise.resolve(answer('FAILED: not allowed to do that')),
      },
      'a.md',
      'x',
    ).then(
      () => null,
      (error: unknown) => error as EditRefused,
    )
    expect(refused).toBeInstanceOf(EditRefused)
    expect(refused?.status).toBe(502)
    expect(refused?.message).toBe('The note was not changed. not allowed to do that')
  })

  it('does not start for a node of a code graph or a note that is not there', async () => {
    const fake = vault({ 'a.md': note('1') })
    let started = false
    const deps = {
      run: fake.run,
      config: defaultConfig,
      harness: 'Claude' as const,
      session: () => {
        started = true
        return Promise.resolve(answer(''))
      },
    }
    const node = await editNote(deps, 'synapse/w@main/N.md', 'x').catch(
      (e: unknown) => e as EditRefused,
    )
    expect(node).toMatchObject({ status: 400 })
    const missing = await editNote(deps, 'nope.md', 'x').catch((e: unknown) => e as EditRefused)
    expect(missing).toMatchObject({ status: 404 })
    expect(started).toBe(false)
  })
})

describe('putting a note back', () => {
  it('writes the text from before when the note is still as the change left it', async () => {
    const fake = vault({ 'a.md': note('2', 'new') })
    await restoreNote(fake.run, defaultConfig, 'a.md', note('1', 'old'), note('2', 'new'))
    expect(fake.files.get('a.md')).toBe(note('1', 'old'))
    expect(fake.writes).toEqual(['a.md'])
  })

  it('refuses when the note was changed again, and writes nothing', async () => {
    const fake = vault({ 'a.md': note('3', 'by hand') })
    const refused = await restoreNote(
      fake.run,
      defaultConfig,
      'a.md',
      note('1', 'old'),
      note('2', 'new'),
    ).then(
      () => null,
      (error: unknown) => error as EditRefused,
    )
    expect(refused?.status).toBe(409)
    expect(refused?.message).toMatch(/changed again/)
    expect(fake.writes).toEqual([])
  })

  it('refuses a graph node, which is never written by hand', async () => {
    const fake = vault({})
    const refused = await restoreNote(
      fake.run,
      defaultConfig,
      'synapse/w@main/N.md',
      'a',
      'b',
    ).catch((error: unknown) => error as EditRefused)
    expect(refused).toMatchObject({ status: 400 })
  })
})

describe('the prompt to change a note', () => {
  it('holds the commands that work for the harnesses that are held to them, and not for Codex', () => {
    expect(editPrompt('a.md', 'x', 'Claude')).toContain('Only these commands work')
    expect(editPrompt('a.md', 'x', 'Opencode')).toContain('Only these commands work')
    expect(editPrompt('a.md', 'x', 'Codex')).not.toContain('Only these commands work')
  })

  it('says to keep what was not asked about, never to change the ids, and what to end with', () => {
    const text = editPrompt('tasks/p/Work.md', 'tick the first item', 'Claude')
    expect(text).toContain(
      'keeping every frontmatter field, section, link and line you were not asked to change',
    )
    expect(text).toContain('Never change `schema`, `note_id`, `task_id`, `created` or `project`')
    expect(text).toContain('synapse-task skill')
    expect(text).toContain('end your reply with the line EDITED')
    expect(text).toContain('FAILED:')
    expect(text).toContain('as a here-document')
  })
})
