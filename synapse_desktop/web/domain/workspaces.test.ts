import { describe, expect, it } from 'vitest'
import { workspaceLabel, workspaceNames } from './workspaces.ts'

describe('the label of a workspace', () => {
  it('is the name of the folder, and the folder it is in', () => {
    expect(workspaceLabel('/Users/a/Development/synapse')).toEqual({
      name: 'synapse',
      parent: '/Users/a/Development',
    })
  })

  it('ignores a slash at the end', () => {
    expect(workspaceLabel('/a/b/')).toEqual({ name: 'b', parent: '/a' })
  })

  it('has the root as the parent of a folder directly in it', () => {
    expect(workspaceLabel('/work')).toEqual({ name: 'work', parent: '/' })
  })

  it('is the whole path for the root and for a path with no separator', () => {
    expect(workspaceLabel('/')).toEqual({ name: '/', parent: '' })
    expect(workspaceLabel('work')).toEqual({ name: 'work', parent: '' })
  })

  it('reads a path of backslashes', () => {
    expect(workspaceLabel('C:\\Users\\a\\code')).toEqual({ name: 'code', parent: 'C:\\Users\\a' })
  })
})

describe('the names of a list of workspaces', () => {
  it('are the names of the folders when they differ', () => {
    expect(workspaceNames(['/a/one', '/a/two'])).toEqual(['one', 'two'])
  })

  it('have the folder above before a name that more than one has', () => {
    expect(workspaceNames(['/d/synapse/main', '/d/eon/main', '/d/other'])).toEqual([
      'synapse/main',
      'eon/main',
      'other',
    ])
  })

  it('keep the name when there is no folder above to tell them apart', () => {
    expect(workspaceNames(['/main', '/x/main'])).toEqual(['main', 'x/main'])
  })
})
