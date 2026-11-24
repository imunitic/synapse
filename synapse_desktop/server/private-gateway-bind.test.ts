import { describe, expect, it } from 'vitest'
import { privateGatewayBind } from './private-gateway-bind.ts'

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
      }),
    ).toBe('0.0.0.0')
  })
})
