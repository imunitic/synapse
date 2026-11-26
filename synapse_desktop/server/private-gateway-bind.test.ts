import { describe, expect, it } from 'vitest'
import { privateGatewayBind, requireIngressProxy } from './private-gateway-bind.ts'

describe('private gateway container binding', () => {
  it('defaults to loopback', () => {
    expect(privateGatewayBind({})).toBe('127.0.0.1')
    expect(privateGatewayBind({ SYNAPSE_PRIVATE_GATEWAY_CONTAINER_BIND: '0' })).toBe('127.0.0.1')
  })

  it('requires explicit config to opt into container networking', () => {
    expect(() => privateGatewayBind({ SYNAPSE_PRIVATE_GATEWAY_CONTAINER_BIND: '1' })).toThrow()
    expect(
      privateGatewayBind({
        SYNAPSE_PRIVATE_GATEWAY_CONTAINER_BIND: '1',
        SYNAPSE_PRIVATE_GATEWAY_CONFIG: '/run/secrets/gateway.json',
        SYNAPSE_PRIVATE_GATEWAY_BIND_ADDRESS: '172.29.103.2',
      }),
    ).toBe('172.29.103.2')
  })
  it.each([undefined, '0.0.0.0', '8.8.8.8', '::'])(
    'rejects an unsafe container ingress address: %s',
    (address) => {
      expect(() =>
        privateGatewayBind({
          SYNAPSE_PRIVATE_GATEWAY_CONTAINER_BIND: '1',
          SYNAPSE_PRIVATE_GATEWAY_CONFIG: '/run/secrets/gateway.json',
          SYNAPSE_PRIVATE_GATEWAY_BIND_ADDRESS: address,
        }),
      ).toThrow()
    },
  )
})

describe('dedicated ingress proxy configuration', () => {
  it('preserves direct loopback mode', () => {
    expect(() => requireIngressProxy('127.0.0.1')).not.toThrow()
  })

  it('requires explicit valid proxy addresses for dedicated ingress', () => {
    expect(() => requireIngressProxy('172.29.103.2')).toThrow()
    expect(() => requireIngressProxy('172.29.103.2', [])).toThrow()
    expect(() => requireIngressProxy('172.29.103.2', ['invalid'])).toThrow()
    expect(() => requireIngressProxy('172.29.103.2', ['172.29.103.3'])).not.toThrow()
  })
})
