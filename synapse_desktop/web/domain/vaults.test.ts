import { describe, expect, it } from 'vitest'
import {
  describeVault,
  isAbsolutePath,
  isEnvName,
  rememberVault,
  withoutVariable,
  withVariable,
} from './vaults.ts'

const vault = {
  path: '/v',
  exists: true,
  hasIndex: true,
  isGit: true,
  notes: 12,
  capped: false,
}

describe('describeVault', () => {
  it('says what a folder holds', () => {
    expect(describeVault(vault)).toBe(
      'A folder with 12 notes, has an Index.md, is a git repository',
    )
    expect(describeVault({ ...vault, hasIndex: false, isGit: false, notes: 1 })).toBe(
      'A folder with 1 note, has no Index.md, is not a git repository',
    )
  })

  it('says when the count stopped early', () => {
    expect(describeVault({ ...vault, notes: 20000, capped: true })).toContain('20000+ notes')
  })

  it('says when there is no folder', () => {
    expect(describeVault({ ...vault, exists: false })).toBe('There is no folder at this path.')
  })
})

describe('paths and names', () => {
  it('knows an absolute path', () => {
    for (const path of ['/a/b', 'C:\\vault', 'D:/vault', '\\\\server\\share']) {
      expect(isAbsolutePath(path)).toBe(true)
    }
    // The home folder is known to the server, which makes it a path.
    for (const path of ['~', '~/v', '~\\v']) expect(isAbsolutePath(path)).toBe(true)
    for (const path of ['', 'vault', './v', '~user/v']) expect(isAbsolutePath(path)).toBe(false)
  })

  it('knows a variable name', () => {
    expect(isEnvName('SYNAPSE_VAULT_DIR')).toBe(true)
    expect(isEnvName('_x1')).toBe(true)
    for (const name of ['', '1X', 'A B', 'A=B', 'A-B']) expect(isEnvName(name)).toBe(false)
  })
})

describe('rememberVault', () => {
  it('puts the vault first, once, and keeps eight', () => {
    expect(rememberVault(['/a', '/b'], '/b')).toEqual(['/b', '/a'])
    const nine = Array.from({ length: 9 }, (_, i) => `/v${i}`)
    const kept = rememberVault(nine, '/new')
    expect(kept).toHaveLength(8)
    expect(kept[0]).toBe('/new')
  })
})

describe('variables', () => {
  it('sets one over another and removes one', () => {
    const env = withVariable(withVariable({}, 'A', '1'), 'A', '2')
    expect(env).toEqual({ A: '2' })
    expect(withoutVariable({ A: '1', B: '2' }, 'A')).toEqual({ B: '2' })
  })

  it('does not change what it is given', () => {
    const env = { A: '1' }
    withVariable(env, 'B', '2')
    withoutVariable(env, 'A')
    expect(env).toEqual({ A: '1' })
  })
})
