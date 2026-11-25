import { describe, expect, it } from 'vitest'
import { isPrivateBackendUrl } from './private-network-bind.ts'

describe('private backend URL', () => {
  it('accepts isolated HTTP backends', () => {
    expect(isPrivateBackendUrl(new URL('http://172.29.101.2:5174'))).toBe(true)
    expect(isPrivateBackendUrl(new URL('http://127.0.0.1:5174'))).toBe(true)
  })

  it.each([
    'http://user:password@172.29.101.2:5174',
    'http://user@127.0.0.1:5174',
    'http://8.8.8.8:5174',
    'https://172.29.101.2:5174',
    'http://172.29.101.2:5174/path',
    'http://172.29.101.2:5174/?secret=value',
    'http://172.29.101.2:5174/#fragment',
  ])('rejects unsafe backend %s', (value) => {
    expect(isPrivateBackendUrl(new URL(value))).toBe(false)
  })
})
