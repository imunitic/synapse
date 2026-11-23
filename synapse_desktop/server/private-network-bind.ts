// Explicit opt-in for an isolated container's private IPv4 interface.
// Never bind a private host to every interface or to a public address.
export function privateNetworkBind(env: Readonly<Record<string, string | undefined>>): string {
  const address = env.SYNAPSE_DESKTOP_PRIVATE_BIND_ADDRESS
  if (address === undefined) return '127.0.0.1'
  if (!env.SYNAPSE_DESKTOP_TOKEN) {
    throw new Error('private network bind requires an explicit backend token')
  }
  const parts = address.split('.')
  if (parts.length !== 4 || parts.some((part) => !/^(0|[1-9][0-9]{0,2})$/.test(part))) {
    throw new Error('private network bind requires a private IPv4 address')
  }
  const octets = parts.map(Number)
  if (octets.some((part) => part > 255)) {
    throw new Error('private network bind requires a private IPv4 address')
  }
  const [first, second] = octets
  if (
    first !== 10 &&
    !(first === 172 && second >= 16 && second <= 31) &&
    !(first === 192 && second === 168)
  ) {
    throw new Error('private network bind requires an RFC1918 IPv4 address')
  }
  return address
}
