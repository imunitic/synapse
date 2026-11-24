// Gateway container binding is explicitly opt-in. The published HTTPS proxy
// must be the only ingress; Docker must not publish this listener publicly.
export function privateGatewayBind(env: Readonly<Record<string, string | undefined>>): string {
  if (env.SYNAPSE_PRIVATE_GATEWAY_CONTAINER_BIND !== '1') return '127.0.0.1'
  if (env.SYNAPSE_PRIVATE_GATEWAY_CONFIG === undefined) {
    throw new Error('container gateway bind requires explicit gateway configuration')
  }
  return '0.0.0.0'
}
