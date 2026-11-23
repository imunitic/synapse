import { describe, expect, it } from 'vitest'
import { isPrivateIpv4, privateNetworkBind } from './private-network-bind.ts'

describe('private container bind address', () => {
  it('classifies only strict RFC1918 addresses for gateway routes', () => {
    expect(isPrivateIpv4('10.42.0.2')).toBe(true)
    expect(isPrivateIpv4('172.31.0.4')).toBe(true)
    expect(isPrivateIpv4('192.168.1.3')).toBe(true)
    for (const address of ['127.0.0.1', '0.0.0.0', '10.0.0.999', '10.01.0.2', '8.8.8.8', 'localhost']) {
      expect(isPrivateIpv4(address)).toBe(false)
    }
  })

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
