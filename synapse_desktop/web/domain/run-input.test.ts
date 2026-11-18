import { describe, expect, it } from 'vitest'
import {
  interactiveProblem,
  previewInput,
  readFolder,
  readInteractive,
  runInput,
  writeFolder,
  writeInteractive,
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

describe('the choice of Interactive', () => {
  function storage() {
    const held = new Map<string, string>()
    return {
      getItem: (key: string) => held.get(key) ?? null,
      setItem: (key: string, value: string) => void held.set(key, value),
      removeItem: (key: string) => void held.delete(key),
    }
  }

  it('is kept for each pipeline and is off until it was made', () => {
    const s = storage()
    expect(readInteractive(s, 'A')).toBe(false)
    writeInteractive(s, 'A', true)
    expect(readInteractive(s, 'A')).toBe(true)
    expect(readInteractive(s, 'B')).toBe(false)
    writeInteractive(s, 'A', false)
    expect(readInteractive(s, 'A')).toBe(false)
  })

  it('is off where the storage cannot be used', () => {
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
    expect(readInteractive(broken, 'A')).toBe(false)
    expect(() => writeInteractive(broken, 'A', true)).not.toThrow()
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
