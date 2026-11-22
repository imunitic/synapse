// A private gateway may identify itself with a dedicated backend Origin.
// This only extends the loopback Node bus handshake allowlist; it does not
// enable remote mode, change the bind address, or bypass the backend token.
type Environment = Readonly<Record<string, string | undefined>>

export function privateBackendOrigin(env: Environment): string[] {
  const value = env.SYNAPSE_DESKTOP_PRIVATE_BACKEND_ORIGIN
  if (value === undefined) return []
  const url = new URL(value)
  if (url.protocol === 'http:' || url.protocol === 'https:') {
    if (url.origin === value) return [value]
  }
  throw new Error('Private backend origin must be an exact HTTP(S) origin')
}
