import { describe, expect, it } from 'vitest'
import {
  interactiveProblem,
  previewInput,
  readFolder,
  readAutonomous,
  runInput,
  writeFolder,
  writeAutonomous,
} from './run-input.ts'

describe('the input of a run', () => {
  it('is the sentence, as a string, in text mode, and none when the box is empty', () => {
    expect(runInput('text', '  add a --verbose flag ', '{}')).toEqual({
      ok: true,
      value: 'add a --verbose flag',
    })
    expect(runInput('text', '   ', '{}')).toEqual({ ok: true, value: undefined })
  })

  it('is the parsed value in JSON mode, whatever it is, and says when it is not JSON', () => {
    expect(runInput('json', 'ignored', '{"task": "x"}')).toEqual({ ok: true, value: { task: 'x' } })
    expect(runInput('json', '', '[1, 2]')).toEqual({ ok: true, value: [1, 2] })
    const bad = runInput('json', '', '{')
    expect(bad.ok).toBe(false)
    expect(bad.ok ? '' : bad.error).toMatch(/not valid JSON/)
  })

  it('is previewed as JSON text, and not at all while there is nothing to show', () => {
    expect(previewInput('text', 'fix it', '{}')).toBe('"fix it"')
    expect(previewInput('text', '', '{}')).toBeUndefined()
    expect(previewInput('json', '', '{"a":1}')).toBe('{"a":1}')
    expect(previewInput('json', '', '{')).toBeUndefined()
  })
})

describe('whether a pipeline can be run interactively', () => {
  it('can when the check passes, warnings or not', () => {
    expect(interactiveProblem({ code: 0, stdout: '', stderr: 'warning: something' })).toBeNull()
  })

  it('gives the lines the check complained of, and not its warnings', () => {
    expect(
      interactiveProblem({
        code: 1,
        stdout: '',
        stderr:
          'warning: a.synapse:1:1: odd\nstep Review runs on Opencode, which cannot run a step interactively\n',
      }),
    ).toBe('step Review runs on Opencode, which cannot run a step interactively')
    expect(interactiveProblem({ code: 1, stdout: '', stderr: '' })).toBe(
      'This pipeline cannot be run interactively.',
    )
  })
})

describe('the choice to run without a terminal', () => {
  function storage() {
    const held = new Map<string, string>()
    return {
      held,
      getItem: (key: string) => held.get(key) ?? null,
      setItem: (key: string, value: string) => void held.set(key, value),
      removeItem: (key: string) => void held.delete(key),
    }
  }

  it('is false until it was made, and is kept for each pipeline', () => {
    const s = storage()
    expect(readAutonomous(s, 'A')).toBe(false)
    writeAutonomous(s, 'A', true)
    expect(readAutonomous(s, 'A')).toBe(true)
    expect(readAutonomous(s, 'B')).toBe(false)
  })

  it('is forgotten when written false', () => {
    const s = storage()
    writeAutonomous(s, 'A', true)
    writeAutonomous(s, 'A', false)
    expect(readAutonomous(s, 'A')).toBe(false)
    expect(s.held.size).toBe(0)
  })

  it('is false where the storage cannot be used', () => {
    const broken = {
      getItem: () => {
        throw new Error('no storage')
      },
      setItem: () => {
        throw new Error('no storage')
      },
      removeItem: () => {
        throw new Error('no storage')
      },
    }
    expect(readAutonomous(broken, 'A')).toBe(false)
    expect(() => writeAutonomous(broken, 'A', true)).not.toThrow()
  })

  it('does not read the old run-interactive key', () => {
    const s = storage()
    s.setItem('run-interactive:A', '1')
    expect(readAutonomous(s, 'A')).toBe(false)
  })
})

describe('the folder of an interactive run', () => {
  function storage() {
    const held = new Map<string, string>()
    return {
      getItem: (key: string) => held.get(key) ?? null,
      setItem: (key: string, value: string) => void held.set(key, value),
      removeItem: (key: string) => void held.delete(key),
    }
  }

  it('is the one kept for the pipeline, else the default folder of the terminals', () => {
    const s = storage()
    expect(readFolder(s, 'A', '/home/me')).toBe('/home/me')
    writeFolder(s, 'A', ' /work/repo ')
    expect(readFolder(s, 'A', '/home/me')).toBe('/work/repo')
    expect(readFolder(s, 'B', '/home/me')).toBe('/home/me')
    writeFolder(s, 'A', '   ')
    expect(readFolder(s, 'A', '/home/me')).toBe('/home/me')
  })
})
