import { describe, expect, it } from 'vitest'
import { privateBackendOrigin } from './private-backend-origin.ts'

describe('private Node backend origin', () => {
  it('keeps the ordinary local host unchanged by default', () => {
    expect(privateBackendOrigin({})).toEqual([])
  })

  it('permits one explicit gateway-generated Origin', () => {
    expect(
      privateBackendOrigin({ SYNAPSE_DESKTOP_PRIVATE_BACKEND_ORIGIN: 'http://gateway.internal' }),
    ).toEqual(['http://gateway.internal'])
  })

  it.each([
    'ftp://gateway.internal',
    'http://gateway.internal/path',
    'http://gateway.internal?x=1',
    'http://user:password@gateway.internal',
    'http://gateway.internal/',
    'not-an-origin',
  ])('rejects a non-origin value: %s', (value) => {
    expect(() =>
      privateBackendOrigin({ SYNAPSE_DESKTOP_PRIVATE_BACKEND_ORIGIN: value }),
    ).toThrow()
  })
})
