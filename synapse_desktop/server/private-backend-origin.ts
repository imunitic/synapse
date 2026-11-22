// A private gateway may identify itself with a dedicated backend Origin.
// This only extends the loopback Node bus handshake allowlist; it does not
// enable remote mode, change the bind address, or bypass the backend token.
export function privateBackendOrigin(
  env: Readonly<Record<string, string | undefined>>,
): string[] {
  const value = env.SYNAPSE_DESKTOP_PRIVATE_BACKEND_ORIGIN
  if (value === undefined) return []
  const url = new URL(value)
  if (
    (url.protocol !== 'http:' && url.protocol !== 'https:') ||
    url.origin !== value ||
    url.username ||
    url.password ||
    url.pathname !== '/' ||
    url.search ||
    url.hash
  ) {
    throw new Error('SYNAPSE_DESKTOP_PRIVATE_BACKEND_ORIGIN must be an exact HTTP(S) origin')
  }
  return [value]
}
