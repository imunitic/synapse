// Gateway container binding is explicitly opt-in. The published HTTPS proxy
// must be the only ingress; Docker must not publish this listener publicly.
import { isIP } from 'node:net'
import { isPrivateIpv4 } from './private-network-bind.ts'

export function privateGatewayBind(env: Readonly<Record<string, string | undefined>>): string {
  if (env.SYNAPSE_PRIVATE_GATEWAY_CONTAINER_BIND !== '1') return '127.0.0.1'
  if (env.SYNAPSE_PRIVATE_GATEWAY_CONFIG === undefined) {
    throw new Error('container gateway bind requires explicit gateway configuration')
  }
  const address = env.SYNAPSE_PRIVATE_GATEWAY_BIND_ADDRESS
  if (!address || !isPrivateIpv4(address)) {
    throw new Error('container gateway requires a private ingress bind address')
  }
  return address
}

export function requireIngressProxy(bindAddress: string, proxies?: readonly string[]): void {
  if (bindAddress === '127.0.0.1') return
  if (!proxies?.length || proxies.some((address) => typeof address !== 'string' || !isIP(address))) {
    throw new Error('private ingress requires explicit trusted proxy IP addresses')
  }
}
