import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { defaultConfig } from '../shared/calls.ts'
import { expandConfigPaths, expandHome } from './home.ts'

const home = join('/', 'Users', 'me')

describe('a path with ~ in it', () => {
  it('is the home folder, or a path in it', () => {
    expect(expandHome('~', home)).toBe(home)
    expect(expandHome('~/Development/synapse', home)).toBe(join(home, 'Development', 'synapse'))
    expect(expandHome('~\\Development', home)).toBe(join(home, 'Development'))
  })

  it('is left alone when the ~ is not the home folder', () => {
    expect(expandHome('/a/~/b', home)).toBe('/a/~/b')
    expect(expandHome('~other/x', home)).toBe('~other/x')
    expect(expandHome('C:/Users/RUNNER~1/x', home)).toBe('C:/Users/RUNNER~1/x')
    expect(expandHome('relative/path', home)).toBe('relative/path')
  })

  it('is left as it is when there is no home folder to put in', () => {
    expect(expandHome('~/x', '')).toBe('~/x')
  })
})

describe('the settings that hold a folder', () => {
  it('have ~ expanded, and the others stay', () => {
    const expanded = expandConfigPaths(
      {
        ...defaultConfig,
        workDir: '~/.cache/synapse/work',
        definitionPaths: ['~/defs', '/abs/defs'],
        terminalFolder: '~',
        graphRepos: { 'a@main': '~/code/a' },
        env: { KEEP: '~/not-a-path' },
      },
      home,
    )
    expect(expanded.workDir).toBe(join(home, '.cache', 'synapse', 'work'))
    expect(expanded.definitionPaths).toEqual([join(home, 'defs'), '/abs/defs'])
    expect(expanded.terminalFolder).toBe(home)
    expect(expanded.graphRepos).toEqual({ 'a@main': join(home, 'code', 'a') })
    expect(expanded.env).toEqual({ KEEP: '~/not-a-path' })
  })

  it('keep nothing as nothing', () => {
    const expanded = expandConfigPaths(defaultConfig, home)
    expect(expanded.workDir).toBeNull()
    expect(expanded.terminalFolder).toBeNull()
  })
})
