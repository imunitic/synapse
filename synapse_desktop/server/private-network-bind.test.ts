import { describe, expect, it } from 'vitest'
import { privateNetworkBind } from './private-network-bind.ts'

describe('private container bind address', () => {
  it('preserves loopback by default', () => {
    expect(privateNetworkBind({})).toBe('127.0.0.1')
  })

  it('accepts only explicitly token-protected RFC1918 addresses', () => {
    for (const address of ['10.8.0.2', '172.16.0.3', '172.31.255.254', '192.168.10.5']) {
      expect(
        privateNetworkBind({
          SYNAPSE_DESKTOP_PRIVATE_BIND_ADDRESS: address,
          SYNAPSE_DESKTOP_TOKEN: 'fixture-token',
        }),
      ).toBe(address)
    }
  })

  it('rejects missing tokens, public addresses, wildcards and malformed addresses', () => {
    expect(() => privateNetworkBind({ SYNAPSE_DESKTOP_PRIVATE_BIND_ADDRESS: '10.8.0.2' })).toThrow()
    for (const address of [
      '0.0.0.0',
      '127.0.0.1',
      '8.8.8.8',
      '169.254.1.2',
      '172.32.0.1',
      '192.169.1.2',
      '10.1.2.999',
      '10.01.2.3',
      '::',
    ]) {
      expect(() =>
        privateNetworkBind({
          SYNAPSE_DESKTOP_PRIVATE_BIND_ADDRESS: address,
          SYNAPSE_DESKTOP_TOKEN: 'fixture-token',
        }),
      ).toThrow()
    }
  })
})
