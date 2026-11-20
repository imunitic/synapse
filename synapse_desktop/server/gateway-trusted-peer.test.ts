import type { IncomingMessage } from 'node:http'
import { describe, expect, it } from 'vitest'
import { createTrustedPeerKey } from './gateway-trusted-peer.ts'

function request(peer: string, forwarded?: string): IncomingMessage {
  return {
    socket: { remoteAddress: peer },
    headers: forwarded === undefined ? {} : { 'x-forwarded-for': forwarded },
  } as IncomingMessage
}

describe('trusted proxy rate limit peer resolution', () => {
  it('ignores forged forwarding headers from untrusted peers', () => {
    const key = createTrustedPeerKey(['127.0.0.1'])
    expect(key(request('198.51.100.7', '203.0.113.45'))).toBe('198.51.100.7')
  })

  it('uses only a single verified forwarded IP from a configured proxy', () => {
    const key = createTrustedPeerKey(['127.0.0.1'])
    expect(key(request('127.0.0.1', '203.0.113.45'))).toBe('203.0.113.45')
    expect(key(request('127.0.0.1', '203.0.113.45, 198.51.100.7'))).toBeNull()
    expect(key(request('127.0.0.1', 'not-an-ip'))).toBeNull()
    expect(key(request('127.0.0.1'))).toBeNull()
  })

  it('rejects invalid trusted proxy configuration', () => {
    expect(() => createTrustedPeerKey(['not-an-ip'])).toThrow()
  })
})
